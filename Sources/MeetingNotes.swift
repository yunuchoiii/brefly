import Foundation

/// 녹음 파일 하나를 회의록으로 만든다. 받아쓰기 → 요약까지를 한 줄로 엮는다.
///
/// 받아쓰기(`fn⌃`)의 정리 경로(`Polisher`)를 쓰지 않는 이유가 셋 있다.
/// 1. 길이가 다르다. 받아쓰기는 몇백 자, 회의록은 35분에 1만 6천 자다.
/// 2. 원하는 결과가 다르다. 받아쓰기는 "말한 그대로 다듬기", 회의록은 "안건·결정·할 일 뽑기"다.
/// 3. 받아쓰기 경로는 말투 판정·억양·용어 치환·불릿 손질이 줄줄이 붙어 있는데, 회의록엔 방해가 된다.
///
/// ⚠️ 온디바이스로는 못 한다. 3B 모델은 긴 글에서 없는 말을 지어내고 결정 사항을 뒤집는다
///    (`CLAUDE.md` 의 "요약은 클라우드가 본체다" 참고). Gemini 로만 보낸다.
enum MeetingNotes {

    struct Result {
        let transcript: String
        let notes: String
        /// 시각이 붙은 낱말 묶음. 원문 탭이 "몇 분에 무슨 말을 했는지" 보여 주는 데 쓴다.
        /// 나중에 화자 구분이 들어오면 이 시각에 화자 구간을 겹쳐 맞춘다.
        let segments: [Whisper.Segment]
        let transcribeSeconds: Double
        let summarizeSeconds: Double
    }

    enum Failure: LocalizedError {
        case noAPIKey
        case badResponse(Int, String)
        case emptyAnswer

        var errorDescription: String? {
            switch self {
            case .noAPIKey:
                return "회의록을 만들려면 Gemini 키가 필요합니다. 설정 > AI 모델에서 넣어 주세요."
            case .badResponse(let code, let body):
                return "요약에 실패했습니다 (\(code)). \(body.prefix(140))"
            case .emptyAnswer:
                return "요약이 비어 있습니다. 녹음이 너무 짧거나 말소리가 없는 것 같습니다."
            }
        }
    }

    /// 회의록 지시문. 받아쓰기 프롬프트와 완전히 따로 둔다.
    ///
    /// **지어내지 말라**를 가장 앞에 둔다. 긴 글을 넣으면 모델이 회의록의 꼴을 갖추려고
    /// 없는 담당자와 마감을 채워 넣는다. 회의록은 그러면 못 쓴다 — 틀린 회의록은 없느니만 못하다.
    private static let instruction = """
        아래 <회의록> 안은 회의를 받아쓴 것이다. 이것을 회의록으로 정리한다.

        가장 중요한 규칙: **원문에 없는 것을 절대 만들지 않는다.**
        - 담당자와 마감은 원문에서 말한 것만 적는다. 없으면 그 항목을 비운다.
        - "누가 말했는지"는 알 수 없다. 화자를 추측해 적지 않는다.
        - 받아쓰기라 잘못 들린 낱말이 섞여 있다. 앞뒤로 뜻이 통하는 쪽으로 읽되, 확신이 없으면 그대로 둔다.

        다음 차례로 쓴다. 해당하는 내용이 없는 항목은 통째로 뺀다.

        ## 한 줄 요약
        회의가 무엇을 다뤘고 무엇이 정해졌는지 한 문장.

        ## 결정된 것
        - 확정된 것만. "하기로 했다" 수준으로 말이 맺힌 것만 적는다.

        ## 할 일
        할 일을 먼저 쓰고, 원문에서 **말한 것만** 뒤에 붙인다. 꼴은 이렇다.

            - <할 일> — <담당자>, <마감>
            - <할 일> — <담당자>
            - <할 일>

        담당자나 마감을 말하지 않았으면 **세 번째 꼴처럼 아무것도 붙이지 않는다.**
        "담당자: (없음)", "마감: 미정" 같은 빈 칸을 만들지 않는다 — 읽을 것만 늘고 아무 정보도 없다.

        ⚠️ 위 꺾쇠는 자리를 보여 주는 표시일 뿐이다. **꺾쇠 안의 말을 결과에 그대로 쓰지 않는다.**
        사람 이름·직함·회사·날짜는 원문에서 실제로 들린 것만 쓴다.

        ## 논의한 것
        - 결론이 안 난 것, 의견이 갈린 것. 왜 갈렸는지까지.

        ## 다음에 볼 것
        - 다음 회의나 후속으로 넘긴 것.

        문체는 '~다'로 쓴다. 인사말·잡담·같은 말 반복은 버린다.
        """

    /// 어느 단계에 있고 얼마나 왔는지. 메뉴바 고리와 팝오버가 같은 값을 쓴다.
    struct Progress {
        enum Stage {
            case transcribing   // 이 맥 안에서 받아쓰는 중
            case summarizing    // 받아 적은 글만 AI 모델로 보내는 중

            var title: String {
                switch self {
                case .transcribing: return "받아쓰는 중"
                case .summarizing:  return "요약하는 중"
                }
            }
        }
        let stage: Stage
        /// 0~1. nil 이면 얼마나 왔는지 알 수 없다 — 요약은 한 번에 답이 오므로 중간이 없다.
        let fraction: Double?
        var text: String {
            guard let fraction else { return stage.title }
            return "\(stage.title) \(Int(fraction * 100))%"
        }
    }

    // MARK: - 한 줄로 엮기

    static func make(audio: URL,
                     cancel: CancelToken? = nil,
                     onProgress: @escaping (Progress) -> Void,
                     completion: @escaping (Swift.Result<Result, Error>) -> Void) {
        onProgress(Progress(stage: .transcribing, fraction: 0))
        let transcribeStarted = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let segments: [Whisper.Segment]
            do {
                segments = try Whisper.transcribe(audio: audio, model: ModelStore.transcriptionModel,
                                                  cancel: cancel,
                                                  onProgress: { onProgress(Progress(stage: .transcribing, fraction: $0)) })
            } catch {
                completion(.failure(error))
                return
            }
            let transcribeSeconds = Date().timeIntervalSince(transcribeStarted)
            // 미리 알려 줬어도 놓치는 것이 있다. 받아쓰기 쪽과 같은 용어집으로 한 번 더 훑는다.
            let heard = segments.map(\.text).joined(separator: " ")
            let transcript = Glossary.apply(to: heard)
            if transcript != heard { Log.write("회의록 용어 치환 적용") }
            guard transcript.count > 30 else {
                completion(.failure(Failure.emptyAnswer))
                return
            }
            // 받아쓰기가 끝난 직후에도 한 번 본다. 여기서 안 막으면 취소해 놓고 요약 요청이 나간다.
            if cancel?.isCancelled == true {
                completion(.failure(Whisper.Failure.cancelled))
                return
            }
            onProgress(Progress(stage: .summarizing, fraction: nil))

            let summarizeStarted = Date()
            summarize(transcript) { result in
                completion(result.map {
                    Result(transcript: transcript,
                           notes: $0,
                           segments: segments,
                           transcribeSeconds: transcribeSeconds,
                           summarizeSeconds: Date().timeIntervalSince(summarizeStarted))
                })
            }
        }
    }

    // MARK: - 모델이 남긴 빈 칸 지우기

    /// "— 담당자: (없음), 마감: (미정)" 처럼 **비었다는 사실만 적은 꼬리표**를 떼어낸다.
    ///
    /// 프롬프트로 여러 번 막아 봤지만 모델은 표의 꼴을 지키려고 계속 빈 칸을 채웠다.
    /// 금지어를 늘리면 "(미정)" 이 "(없음)" 으로 바뀔 뿐이었고, 빈 칸 대신 예시를 보여 줬더니
    /// **예시에 쓴 사람 이름을 결과에 그대로 베껴 넣었다**(2026-09-29, 원문에 없는 "김 과장"이 담당자로
    /// 올라갔다). 회의록에 없는 담당자가 생기는 쪽이 훨씬 나쁘다.
    ///
    /// 그래서 프롬프트는 안전한 쪽(꺾쇠 자리표시)으로 두고, 꼬리표는 코드가 지운다.
    /// 확률에 기대는 것보다 확실하다.
    static func tidy(_ text: String) -> String {
        let empty = "(?:\\(?(?:없음|미정|없습니다|해당\\s*없음|TBD|N/?A|-)\\)?)"
        let label = "(?:담당자|담당|마감|기한|일정)"
        let patterns = [
            // "— 담당자: (없음), 마감: (없음)" 처럼 꼬리 전체가 빈 칸뿐이면 꼬리째 지운다
            "\\s*[—–-]\\s*(?:\(label)\\s*[:：]?\\s*\(empty)\\s*[,·]?\\s*)+$",
            // "…, 마감: 미정" 처럼 뒤쪽 하나만 비었으면 그것만 지운다
            "\\s*[,·]\\s*\(label)\\s*[:：]?\\s*\(empty)\\s*$",
        ]
        var lines = text.components(separatedBy: .newlines)
        for i in lines.indices {
            for pattern in patterns {
                lines[i] = lines[i].replacingOccurrences(of: pattern, with: "",
                                                         options: [.regularExpression], range: nil)
            }
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 요약

    /// ⚠️ 받아쓰기 쪽 Gemini 호출(`GeminiClient`)을 그대로 쓰지 않는다. 거기는 출력이 2048 토큰으로
    ///    묶여 있고 `PolishStyle` 에 매여 있어서, 회의록을 넣으면 중간에 잘린다.
    ///    호출 코드가 두 벌이 된 셈인데, 받아쓰기 쪽을 건드려 짧은 말 처리를 흔드는 것보다 낫다고 봤다.
    private static func summarize(_ transcript: String,
                                  completion: @escaping (Swift.Result<String, Error>) -> Void) {
        guard let key = KeychainStore.read(.gemini), !key.isEmpty else {
            completion(.failure(Failure.noAPIKey))
            return
        }
        let model = Prefs.geminiModel
        guard let url = URL(string:
            "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent") else {
            completion(.failure(Failure.badResponse(0, "주소를 만들지 못했습니다")))
            return
        }

        let body: [String: Any] = [
            "contents": [["parts": [["text": "\(instruction)\n\n<회의록>\n\(transcript)\n</회의록>"]]]],
            "generationConfig": [
                "temperature": 0.2,
                // 회의록은 길다. 받아쓰기 쪽 2048 로는 표가 중간에 끊긴다.
                "maxOutputTokens": 8192,
            ],
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(key, forHTTPHeaderField: "x-goog-api-key")
        request.httpBody = try? JSONSerialization.data(withJSONObject: body)
        // 긴 글이라 오래 걸린다. 받아쓰기 쪽 기본값으로는 끊긴다.
        request.timeoutInterval = 180

        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                completion(.failure(error))
                return
            }
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard let data, (200..<300).contains(code) else {
                completion(.failure(Failure.badResponse(code, String(data: data ?? Data(), encoding: .utf8) ?? "")))
                return
            }
            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let candidates = json["candidates"] as? [[String: Any]],
                  let content = candidates.first?["content"] as? [String: Any],
                  let parts = content["parts"] as? [[String: Any]] else {
                completion(.failure(Failure.badResponse(code, String(data: data, encoding: .utf8) ?? "")))
                return
            }
            let text = tidy(parts.compactMap { $0["text"] as? String }.joined())
            completion(text.isEmpty ? .failure(Failure.emptyAnswer) : .success(text))
        }.resume()
    }
}
