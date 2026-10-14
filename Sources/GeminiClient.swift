import Foundation

enum GeminiError: LocalizedError {
    case noAPIKey
    case http(Int, String)
    case badResponse
    case blocked(String)

    var errorDescription: String? {
        switch self {
        case .noAPIKey:
            return """
                Gemini API 키가 없습니다.
                aistudio.google.com/apikey 에서 무료로 발급받아
                메뉴 > 'Gemini API 키 설정…'에 넣어 주세요. 카드 등록 필요 없습니다.
                """
        case .http(let code, let body):
            return APIErrorText.describe(service: "Gemini", code: code, body: body)
        case .badResponse:
            return "Gemini 응답을 해석하지 못했습니다."
        case .blocked(let reason):
            return "Gemini가 응답을 거부했습니다: \(reason)"
        }
    }
}

/// Google AI Studio(Gemini) API. 무료 티어가 있고 응답이 빠르다.
struct GeminiClient {

    static let shared = GeminiClient()

    private let base = "https://generativelanguage.googleapis.com/v1beta"

    // MARK: - 정리

    func polish(_ raw: String,
                model: String,
                style: PolishStyle,
                completion: @escaping (Result<String, Error>) -> Void) {
        var chain = [model]
        for m in Prefs.geminiFallbacks where !chain.contains(m) { chain.append(m) }
        HedgedRequest(client: self, raw: raw, chain: chain, style: style, completion: completion).start()
    }

    /// 헤지 요청: 첫 모델을 쏘고, 4초 안에 답이 없거나 503/429/5xx 가 오면 다음 모델을 "추가로" 쏜다.
    /// 먼저 성공한 응답을 쓰고 나머지는 버린다. 무료 티어라 요청 두어 개 겹치는 비용은 없다.
    /// 2026-09-04 밤 실측: 같은 모델이 3초였다 15초였다 하고 503도 섞여서, 순차 재시도로는 20초를 넘겼다.
    private final class HedgedRequest {
        static let hedgeDelay: TimeInterval = 2.5

        private let client: GeminiClient
        private let raw: String
        private let chain: [String]
        private let style: PolishStyle
        private let completion: (Result<String, Error>) -> Void
        private let lock = NSLock()
        private var started = 0
        private var finished = 0
        private var done = false
        private var lastError: Error?
        /// 답은 왔는데 뜻을 바꾸는 말(왜·안…)을 빠뜨린 것이 있었는가. 다른 모델이 다 실패하면 원문을 넣는다.
        private var sawLossy = false
        private let startedAt = Date()

        init(client: GeminiClient, raw: String, chain: [String], style: PolishStyle,
             completion: @escaping (Result<String, Error>) -> Void) {
            self.client = client; self.raw = raw; self.chain = chain; self.style = style; self.completion = completion
        }

        /// 첫 두 모델은 동시에 쏜다. 무료 티어에서 한 모델이 503/타임아웃일 확률이 높아서,
        /// 3초를 기다렸다 두 번째를 쏘는 것보다 처음부터 겹치는 게 평균 1~2초 빠르다 (2026-09-04 밤 실측).
        func start() {
            fireNext()
            if chain.count > 1 { fireNext() }
        }

        private func fireNext() {
            lock.lock()
            guard !done, started < chain.count else { lock.unlock(); return }
            let index = started
            started += 1
            lock.unlock()

            let model = chain[index]
            if index > 0 {
                Log.write("Gemini 헤지: \(model) 추가 요청 (\(String(format: "%.1f", Date().timeIntervalSince(startedAt)))초)")
                Polisher.report("\(chain[0]) 응답이 늦어 \(model) 에도 요청 중…")
            }
            client.send(raw, model: model, style: style) { [self] result in
                lock.lock()
                finished += 1
                if done { lock.unlock(); return }
                // ⚠️ 먼저 온 답이라도 의문사·부정어를 빠뜨렸으면 쓰지 않는다. 가장 빨리 오는 flash-lite 가
                //    "왜 PC랑 생긴 게 달라?"를 "PC와 생긴 게 달라."로 바꿨다(2026-10-14). 다음 모델을 기다리고,
                //    모두 그러면 원문을 넣는다 — 군말이 남는 게 뜻이 바뀌는 것보다 낫다.
                //    요약 스타일은 원래 말을 덜어 내므로 보지 않는다.
                var lostWords: [String] = []
                if case .success(let text) = result, style != .summary {
                    lostWords = Polisher.lostMeaningWords(raw: raw, polished: text)
                }
                switch result {
                case .success where lostWords.isEmpty:
                    done = true
                    lock.unlock()
                    if index > 0 { Log.write("Gemini: \(chain[0]) 대신 \(model) 응답 채택") }
                    completion(result)
                case .success:
                    sawLossy = true
                    let exhausted = started >= chain.count && finished >= started
                    if exhausted { done = true }
                    lock.unlock()
                    Log.write("Gemini \(model) 답이 뜻을 바꾸는 말을 뺐다(\(lostWords.joined(separator: ", "))) — 쓰지 않는다")
                    if exhausted {
                        Log.write("Gemini 모든 답이 뜻을 바꿔 원문을 넣는다")
                        completion(.success(raw))
                    } else {
                        fireNext()
                    }
                case .failure(let error):
                    lastError = error
                    let exhausted = started >= chain.count && finished >= started
                    if exhausted { done = true }
                    let lossyBefore = sawLossy
                    lock.unlock()
                    if exhausted && lossyBefore {
                        Log.write("Gemini 모든 답이 뜻을 바꿨거나 실패해 원문을 넣는다")
                        completion(.success(raw))
                    } else if exhausted {
                        completion(.failure(error))
                    } else {
                        // 일시 오류든 아니든 이 모델은 글렀으니 다음 모델을 바로 쏜다.
                        Log.write("Gemini \(model) 실패 — 다음 모델")
                        fireNext()
                    }
                }
            }

            // 답이 늦으면 기다리지 않고 다음 모델을 겹쳐 쏜다.
            DispatchQueue.global().asyncAfter(deadline: .now() + Self.hedgeDelay) { [self] in
                lock.lock()
                let stillWaiting = !done && finished < started
                lock.unlock()
                if stillWaiting { fireNext() }
            }
        }
    }

    fileprivate func send(_ raw: String,
                      model: String,
                      style: PolishStyle,
                      completion: @escaping (Result<String, Error>) -> Void) {

        guard let key = KeychainStore.read(.gemini), !key.isEmpty else {
            completion(.failure(GeminiError.noAPIKey))
            return
        }
        guard let url = URL(string: "\(base)/models/\(model):generateContent") else {
            completion(.failure(GeminiError.badResponse))
            return
        }

        // thinkingConfig 는 보내지 않는다. flash-lite 계열이 400으로 거부해 호출마다 왕복을 한 번 버렸고,
        // 받아주는 모델(3.1-flash-lite)에서는 오히려 3초 → 25초로 느려졌다 (2026-09-04 실측).
        let generationConfig: [String: Any] = [
            "temperature": 0.3,
            "maxOutputTokens": 2048
        ]

        let body: [String: Any] = [
            "systemInstruction": ["parts": [["text": Prompts.system(for: style)]]],
            "contents": [["role": "user", "parts": [["text": Prompts.userMessage(raw, style: style)]]]],
            "generationConfig": generationConfig
        ]

        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        // 무료 티어가 막힐 땐 30초씩 매달려 있는 게 최악이었다(2026-09-04 22:19, 모델 둘이 30초 타임아웃).
        req.timeoutInterval = 8
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let started = Date()
        URLSession.shared.dataTask(with: req) { data, response, error in
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))

            if let error {
                Log.write("Gemini 네트워크 오류: \(error.localizedDescription)")
                completion(.failure(error)); return
            }
            guard let data, let http = response as? HTTPURLResponse else {
                completion(.failure(GeminiError.badResponse)); return
            }
            guard (200..<300).contains(http.statusCode) else {
                let text = String(data: data, encoding: .utf8) ?? ""
                Log.write("Gemini HTTP \(http.statusCode): \(text.prefix(300))")
                completion(.failure(GeminiError.http(http.statusCode, text))); return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure(GeminiError.badResponse)); return
            }

            // 안전 필터에 걸린 경우
            if let feedback = json["promptFeedback"] as? [String: Any],
               let reason = feedback["blockReason"] as? String {
                completion(.failure(GeminiError.blocked(reason))); return
            }

            guard
                let candidates = json["candidates"] as? [[String: Any]],
                let first = candidates.first,
                let content = first["content"] as? [String: Any],
                let parts = content["parts"] as? [[String: Any]]
            else {
                Log.write("Gemini 응답 해석 실패: \(String(data: data, encoding: .utf8)?.prefix(300) ?? "")")
                completion(.failure(GeminiError.badResponse)); return
            }

            let text = parts.compactMap { $0["text"] as? String }
                .joined()
                .trimmingCharacters(in: .whitespacesAndNewlines)

            Log.write("Gemini \(model) 응답 \(text.count)자, \(elapsed)초")
            if text.isEmpty {
                completion(.failure(GeminiError.badResponse))
            } else {
                completion(.success(text))
            }
        }.resume()
    }

    // MARK: - 진단

    /// 이 키로 쓸 수 있는 모델 목록. 모델 이름은 수시로 바뀌므로 직접 조회한다.
    func listModels(_ completion: @escaping (Result<[String], Error>) -> Void) {
        guard let key = KeychainStore.read(.gemini), !key.isEmpty else {
            completion(.failure(GeminiError.noAPIKey)); return
        }
        guard let url = URL(string: "\(base)/models?pageSize=200") else {
            completion(.failure(GeminiError.badResponse)); return
        }

        var req = URLRequest(url: url)
        req.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        req.timeoutInterval = 20

        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error { completion(.failure(error)); return }
            guard let data, let http = response as? HTTPURLResponse else {
                completion(.failure(GeminiError.badResponse)); return
            }
            guard (200..<300).contains(http.statusCode) else {
                completion(.failure(GeminiError.http(http.statusCode,
                                                     String(data: data, encoding: .utf8) ?? ""))); return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["models"] as? [[String: Any]] else {
                completion(.failure(GeminiError.badResponse)); return
            }

            let names = models
                .filter { ($0["supportedGenerationMethods"] as? [String])?.contains("generateContent") ?? true }
                .compactMap { $0["name"] as? String }
                .map { $0.replacingOccurrences(of: "models/", with: "") }
                .sorted()

            completion(.success(names))
        }.resume()
    }
}
