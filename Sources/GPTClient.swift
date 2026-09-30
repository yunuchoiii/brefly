import Foundation

/// OpenAI(ChatGPT) API 로 받아쓴 글을 정리한다.
///
/// `GeminiClient` 와 따로 두는 이유는 요청 모양이 아예 다르기 때문이다 —
/// Gemini 는 `systemInstruction` + `contents`, 이쪽은 `messages` 배열이다.
///
/// ⚠️ **ChatGPT 구독과 요금이 따로 나간다.** Plus 를 결제해도 API 크레딧은 0원이고,
///    이 키로 부르는 것은 전부 별도 청구다. 키를 받는 창에도 같은 말을 적어 둔다.
enum GPTError: LocalizedError {
    case noAPIKey
    case http(Int, String)
    case badResponse
    case empty

    var errorDescription: String? {
        switch self {
        case .noAPIKey:            return "ChatGPT API 키가 없습니다. 설정 > AI 모델에서 넣어 주세요."
        case .http(let code, let body):
            // 없는 모델 이름을 부르면 404 다. 이름이 바뀌었을 때 원인을 바로 알 수 있게 적는다.
            if code == 404 { return "그 이름의 모델이 없습니다 (404). 모델 이름이 바뀌었을 수 있습니다." }
            return "ChatGPT 요청이 실패했습니다 (\(code)). \(body.prefix(140))"
        case .badResponse:         return "ChatGPT 응답을 읽지 못했습니다."
        case .empty:               return "ChatGPT 응답이 비어 있습니다."
        }
    }
}

final class GPTClient {
    static let shared = GPTClient()
    private let endpoint = "https://api.openai.com/v1/chat/completions"

    /// 받아쓰기 정리. 고른 모델이 404(퇴역)·5xx 면 다음 이름으로 넘어간다.
    func polish(_ raw: String, model: String, style: PolishStyle,
                completion: @escaping (Swift.Result<String, Error>) -> Void) {
        var chain = [model]
        for m in Prefs.modelNames(.openai, Prefs.tier) where !chain.contains(m) { chain.append(m) }
        attempt(raw, style: style, chain: chain, index: 0, completion: completion)
    }

    private func attempt(_ raw: String, style: PolishStyle, chain: [String], index: Int,
                         completion: @escaping (Swift.Result<String, Error>) -> Void) {
        let model = chain[index]
        send(system: Prompts.system(for: style),
             user: Prompts.userMessage(raw, style: style),
             // 짧은 받아쓰기라도 추론 모델은 생각부터 한다. 2048 로 묶으면 생각만 하다 끝난다.
             model: model, maxTokens: 4096, timeout: 30) { result in
            if case .failure(let error) = result, index + 1 < chain.count, Self.worthNextModel(error) {
                Log.write("ChatGPT \(model) 실패 — \(chain[index + 1]) 로 넘어감")
                self.attempt(raw, style: style, chain: chain, index: index + 1, completion: completion)
                return
            }
            completion(result)
        }
    }

    /// 모델을 바꿔서 다시 걸어 볼 값어치가 있는 실패인가.
    /// 키가 틀렸거나(401) 요청이 잘못됐으면(400) 다른 모델로도 똑같이 실패한다.
    static func worthNextModel(_ error: Error) -> Bool {
        guard case GPTError.http(let code, _) = error else { return false }
        return code == 404 || code == 429 || (500..<600).contains(code)
    }

    /// 한 번 부른다. 회의록 쪽(`MeetingNotes`)도 이걸 쓴다 — 거기는 글이 길어서
    /// `maxTokens` 와 `timeout` 을 다르게 준다.
    func send(system: String, user: String, model: String,
              maxTokens: Int, timeout: TimeInterval,
              completion: @escaping (Swift.Result<String, Error>) -> Void) {
        guard let key = KeychainStore.read(.openai), !key.isEmpty else {
            completion(.failure(GPTError.noAPIKey)); return
        }
        guard let url = URL(string: endpoint) else {
            completion(.failure(GPTError.badResponse)); return
        }
        // ⚠️ `temperature` 를 보내지 않는다. 최신 추론 모델은 기본값(1)만 받고 다른 값을 주면
        //    400 으로 거부한다 — "Only the default (1) value is supported" (2026-09-30 실측,
        //    gpt-5.5). 회의록은 낮은 온도를 쓰고 싶지만 그 대가로 요청 자체가 실패하면 안 된다.
        //    지어낸 말은 온도가 아니라 프롬프트의 "원문에 없는 것을 절대 만들지 않는다"로 막는다.
        let body: [String: Any] = [
            "model": model,
            "messages": [["role": "system", "content": system],
                         ["role": "user", "content": user]],
            // ⚠️ 새 모델은 `max_tokens` 를 거부하고 `max_completion_tokens` 를 요구한다.
            //    둘 다 보내면 400 이라 새 이름만 보낸다. 안 받는 옛 모델은 무시하고 지나간다.
            "max_completion_tokens": maxTokens,
        ]
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)

        let started = Date()
        URLSession.shared.dataTask(with: req) { data, response, error in
            let elapsed = String(format: "%.1f", Date().timeIntervalSince(started))
            if let error {
                Log.write("ChatGPT 네트워크 오류: \(error.localizedDescription)")
                completion(.failure(error)); return
            }
            guard let data, let http = response as? HTTPURLResponse else {
                completion(.failure(GPTError.badResponse)); return
            }
            guard (200..<300).contains(http.statusCode) else {
                let text = String(data: data, encoding: .utf8) ?? ""
                Log.write("ChatGPT HTTP \(http.statusCode) (\(elapsed)초): \(text.prefix(300))")
                completion(.failure(GPTError.http(http.statusCode, text))); return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let message = choices.first?["message"] as? [String: Any],
                  let text = message["content"] as? String else {
                completion(.failure(GPTError.badResponse)); return
            }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            Log.write("ChatGPT \(model) 응답 \(trimmed.count)자, \(elapsed)초")
            completion(trimmed.isEmpty ? .failure(GPTError.empty) : .success(trimmed))
        }.resume()
    }

    /// 진단용 — 이 키로 실제 쓸 수 있는 모델 목록. 이름이 바뀌었는지 확인할 때 쓴다.
    func listModels(completion: @escaping (Swift.Result<[String], Error>) -> Void) {
        guard let key = KeychainStore.read(.openai), !key.isEmpty else {
            completion(.failure(GPTError.noAPIKey)); return
        }
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/models")!)
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { data, _, error in
            if let error { completion(.failure(error)); return }
            guard let data,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let list = json["data"] as? [[String: Any]] else {
                completion(.failure(GPTError.badResponse)); return
            }
            completion(.success(list.compactMap { $0["id"] as? String }.sorted()))
        }.resume()
    }
}
