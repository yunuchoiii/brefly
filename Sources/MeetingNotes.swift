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
        /// 요약이 끝내 실패했으면 그 까닭. `notes` 에는 받아 적은 원문이 들어 있다.
        ///
        /// ⚠️ 요약 실패를 `.failure` 로 돌려주지 않는 이유가 이것이다. 2026-09-29 에
        ///    48분 회의를 4분 30초 걸려 받아 적고 나서 Gemini 503 하나에 통째로 버렸다.
        ///    받아쓰기는 되돌릴 수 없고 요약은 다시 부르면 그만이다. 비싼 쪽이 싼 쪽의
        ///    성공에 매달리면 안 된다.
        var summaryFailed: Error? = nil
    }

    /// 요약이 실패했을 때 대신 저장할 본문. 받아 적은 것을 그대로 담는다 —
    /// 요약은 몇 초면 다시 부르지만 받아쓰기는 그렇지 않다.
    static func transcriptOnlyNotes(_ transcript: String, error: Error) -> String {
        """
        ## 요약하지 못했습니다

        \(error.localizedDescription)

        받아 적은 것은 아래에 그대로 두었습니다. 창 위의 **다시 요약**을 누르면
        받아쓰기를 다시 하지 않고 요약만 다시 부릅니다.

        ## 받아 적은 원문

        \(transcript)
        """
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
    /// 화자를 아는 경우에 앞에 덧붙이는 말. 직접 녹음하면 마이크=나, 시스템 소리=상대로
    /// 채널이 갈려 있어서 누가 말했는지 안다. 그때는 "추측하지 말라"가 오히려 방해가 된다.
    private static let speakerNote = """
        각 줄 앞의 "나:" 와 "상대:" 는 실제로 갈라 녹음한 것이라 믿어도 된다.
        다만 "상대" 안에 여러 사람이 섞여 있을 수 있다. 몇 명인지는 알 수 없으므로 세지 않는다.
        담당자를 적을 때 "나"/"상대" 말고 실제 이름은 원문에서 부른 것만 쓴다.

        """

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

    /// - Parameter onTranscript: 받아쓰기가 끝나는 **즉시** 부른다. 요약을 부르기 전이다.
    ///   부르는 쪽이 여기서 원문을 디스크에 떨궈 둔다 — 그 뒤로는 무슨 일이 나도 안 잃는다.
    static func make(audio: URL,
                     cancel: CancelToken? = nil,
                     onProgress: @escaping (Progress) -> Void,
                     onTranscript: ((String, [Whisper.Segment]) -> Void)? = nil,
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
            // 여기서 원문을 넘긴다. 요약 전이다 — 이 뒤로는 요약이 어떻게 되든 안 잃는다.
            onTranscript?(transcript, segments)
            onProgress(Progress(stage: .summarizing, fraction: nil))

            let summarizeStarted = Date()
            summarize(transcript) { result in
                completion(.success(assemble(result, transcript: transcript, segments: segments,
                                             transcribeSeconds: transcribeSeconds,
                                             summarizeStarted: summarizeStarted)))
            }
        }
    }

    /// 요약 결과를 `Result` 로 엮는다. **실패해도 `.failure` 로 돌려주지 않는다** —
    /// 받아 적은 것을 본문에 담아 그대로 저장되게 한다.
    private static func assemble(_ result: Swift.Result<String, Error>,
                                 transcript: String, segments: [Whisper.Segment],
                                 transcribeSeconds: Double, summarizeStarted: Date) -> Result {
        let elapsed = Date().timeIntervalSince(summarizeStarted)
        switch result {
        case .success(let notes):
            return Result(transcript: transcript, notes: notes, segments: segments,
                          transcribeSeconds: transcribeSeconds, summarizeSeconds: elapsed)
        case .failure(let error):
            Log.write("요약 실패 — 받아 적은 원문으로 저장한다: \(error.localizedDescription)")
            return Result(transcript: transcript,
                          notes: transcriptOnlyNotes(transcript, error: error),
                          segments: segments,
                          transcribeSeconds: transcribeSeconds, summarizeSeconds: elapsed,
                          summaryFailed: error)
        }
    }


    /// 직접 녹음한 회의. 마이크(나)와 시스템 소리(상대)가 따로 있다.
    ///
    /// 파일 하나를 넣는 것과 다른 점은 **누가 말했는지 안다**는 것이다. 화상회의에서는
    /// 이 갈래가 곧 화자 구분이라, 화자 분리 모델 없이도 "나 / 상대"를 가를 수 있다.
    static func makeFromTracks(mic: URL, system: URL?, recordedAt: Date,
                               cancel: CancelToken? = nil,
                               onProgress: @escaping (Progress) -> Void,
                               onTranscript: ((String, [Whisper.Segment]) -> Void)? = nil,
                               completion: @escaping (Swift.Result<Result, Error>) -> Void) {
        onProgress(Progress(stage: .transcribing, fraction: 0))
        let started = Date()
        DispatchQueue.global(qos: .userInitiated).async {
            let model = ModelStore.transcriptionModel
            let hasSystem = system != nil
            do {
                // 두 트랙을 잇달아 받아쓴다. 진행률은 둘을 합쳐 하나로 보여 준다 —
                // 0%까지 갔다가 다시 0%부터 오르면 멈춘 줄 안다.
                let micSegments = try Whisper.transcribe(
                    audio: mic, model: model, cancel: cancel,
                    onProgress: { onProgress(Progress(stage: .transcribing,
                                                      fraction: hasSystem ? $0 / 2 : $0)) })
                var systemSegments: [Whisper.Segment] = []
                if let system {
                    systemSegments = try Whisper.transcribe(
                        audio: system, model: model, cancel: cancel,
                        onProgress: { onProgress(Progress(stage: .transcribing, fraction: 0.5 + $0 / 2)) })
                }

                // 용어 치환은 합친 글에 한 번만 건다.
                let merged = Glossary.apply(to: EchoFilter.merge(mic: micSegments, system: systemSegments))
                let transcribeSeconds = Date().timeIntervalSince(started)
                guard merged.count > 30 else {
                    completion(.failure(Failure.emptyAnswer))
                    return
                }
                if cancel?.isCancelled == true {
                    completion(.failure(Whisper.Failure.cancelled))
                    return
                }
                // ⚠️ 화면에 보여 줄 구간은 **시각순으로 엮고 화자를 붙여** 둔다.
                //    전에는 `micSegments + systemSegments` 로 이어 붙여서, 원문 탭이
                //    내 말 전부 → 상대 말 전부 순서로 나오고 시각이 중간에 0 으로 되돌아갔다.
                //    에코도 안 걸러져서 상대 말이 두 번 보였다.
                let shown = EchoFilter.labelled(mic: micSegments, system: systemSegments)
                onTranscript?(merged, shown)
                onProgress(Progress(stage: .summarizing, fraction: nil))
                let summarizeStarted = Date()
                summarize(merged, speakersKnown: hasSystem) { result in
                    completion(.success(assemble(result, transcript: merged, segments: shown,
                                                 transcribeSeconds: transcribeSeconds,
                                                 summarizeStarted: summarizeStarted)))
                }
            } catch {
                completion(.failure(error))
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
            // "— (담당자 없음)" 처럼 이름표까지 통째로 괄호에 든 꼴. 2026-09-29 에 모델이
            // 이 모양을 새로 만들어 내서 아래 규칙들을 모두 빠져나갔다.
            "\\s*[—–-]\\s*\\(\\s*\(label)\\s*(?:없음|미정|미상|불명)\\s*\\)\\s*$",
            "\\s*[,·]\\s*\\(\\s*\(label)\\s*(?:없음|미정|미상|불명)\\s*\\)\\s*$",
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
    /// 이미 받아 적어 둔 글로 요약만 다시 부른다. 요약이 503 으로 죽어도 받아쓰기를
    /// 4분 30초 다시 돌리지 않게 하려고 연다. `--summarize-transcript` 와 "다시 요약"이 쓴다.
    static func summarizeOnly(_ transcript: String, speakersKnown: Bool = false,
                              completion: @escaping (Swift.Result<String, Error>) -> Void) {
        summarize(transcript, speakersKnown: speakersKnown, completion: completion)
    }

    /// 저녁이면 무료 티어가 503 을 자주 뱉는다(CLAUDE.md 의 실측). 한 번 튕겼다고 포기하면
    /// 몇 분 걸려 받아 적은 것이 쓸모없어진다. 뒤로 물러서며 다시 걸고, 그래도 안 되면 모델을 바꾼다.
    ///
    /// ⚠️ 무료 키는 **모델당 하루 20회**라 보조 모델도 금방 바닥난다. 그래서 모델을 바꾸기 전에
    ///    같은 모델로 먼저 기다렸다 다시 건다 — 503 은 대개 잠깐이다.
    private static let retryDelays: [Double] = [2, 6, 15]

    /// 회의록은 **받아쓰기와 따로 고른 모델**로 요약한다. 받아쓰기는 커서에 바로 들어가야 해서
    /// 속도가 먼저고, 회의록은 이미 받아쓰기에 2~5분을 썼으니 잘 뽑는 게 먼저다.
    /// ⚠️ 0.8.2 까지는 설정을 아예 안 보고 Gemini 로만 갔다.
    private static func summarize(_ transcript: String, speakersKnown: Bool = false,
                                  completion: @escaping (Swift.Result<String, Error>) -> Void) {
        // AUTO 면 키가 있는 회사를 **가성비 순으로 줄 세워** 차례로 시도한다.
        // 하나도 없으면 Gemini 를 시도해 "키가 없습니다" 안내가 나가게 둔다 —
        // 조용히 아무 일도 안 하는 것보다 낫다.
        //
        // ⚠️ 전에는 이 목록에서 `.first` 하나만 꺼내 썼다. 그래서 Gemini 가 다 실패하면
        //    ChatGPT·Claude 키가 있어도 그냥 실패했다. 회의록은 받아쓰기에 4~5분을 쓴 뒤라
        //    거기서 포기하면 그 시간이 날아간다. 회사를 넘어가는 것이 안전망으로 값어치가 크다.
        let chain: [Prefs.Choice] = Prefs.meetingBackend == .auto
            ? (Prefs.autoCandidates(for: .meeting).isEmpty
               ? [Prefs.Choice(backend: .gemini, tier: .quality)]
               : Prefs.autoCandidates(for: .meeting))
            : [Prefs.meetingChoice]
        Log.write("회의록 요약 차례: " + chain.map(\.title).joined(separator: " → "))
        tryChoice(transcript, speakersKnown: speakersKnown, chain: chain, index: 0, completion: completion)
    }

    /// 회사를 하나씩 내려가며 시도한다. 한 회사 안에서는 `attempt` 가 모델과 재시도를 맡는다.
    private static func tryChoice(_ transcript: String, speakersKnown: Bool,
                                  chain: [Prefs.Choice], index: Int,
                                  completion: @escaping (Swift.Result<String, Error>) -> Void) {
        let chosen = chain[index]
        let models = Prefs.modelNames(chosen.backend, chosen.tier)
        Log.write("회의록 요약: \(chosen.backend.shortTitle) \(chosen.tier.suffix) — \(models.first ?? "?")")
        attempt(transcript, speakersKnown: speakersKnown,
                backend: chosen.backend, models: models.isEmpty ? [Prefs.geminiModel] : models,
                modelIndex: 0, tryIndex: 0) { result in
            if case .failure(let error) = result, index + 1 < chain.count {
                Log.write("회의록 \(chosen.backend.shortTitle) 실패 — \(chain[index + 1].title) 로 넘어감: "
                          + error.localizedDescription.prefix(80))
                tryChoice(transcript, speakersKnown: speakersKnown,
                          chain: chain, index: index + 1, completion: completion)
                return
            }
            completion(result)
        }
    }

    /// 같은 모델로 `retryDelays` 만큼 물러서며 다시 걸고, 다 쓰면 다음 모델로 넘어간다.
    private static func attempt(_ transcript: String, speakersKnown: Bool,
                                backend: Prefs.Backend, models: [String],
                                modelIndex: Int, tryIndex: Int,
                                completion: @escaping (Swift.Result<String, Error>) -> Void) {
        let model = models[min(modelIndex, models.count - 1)]
        call(transcript, speakersKnown: speakersKnown, backend: backend, model: model) { result in
            switch result {
            case .success:
                if modelIndex > 0 || tryIndex > 0 { Log.write("요약 성공 — \(model), \(tryIndex + 1)번째 시도") }
                completion(result)
            case .failure(let error):
                guard worthRetrying(error) else { completion(result); return }
                if tryIndex < retryDelays.count {
                    let wait = retryDelays[tryIndex]
                    Log.write("요약 재시도 — \(model), \(wait)초 뒤 (\(error.localizedDescription.prefix(60)))")
                    DispatchQueue.global().asyncAfter(deadline: .now() + wait) {
                        attempt(transcript, speakersKnown: speakersKnown, backend: backend, models: models,
                                modelIndex: modelIndex, tryIndex: tryIndex + 1, completion: completion)
                    }
                    return
                }
                if modelIndex + 1 < models.count {
                    Log.write("요약 모델 바꿈 — \(model) → \(models[modelIndex + 1])")
                    attempt(transcript, speakersKnown: speakersKnown, backend: backend, models: models,
                            modelIndex: modelIndex + 1, tryIndex: 0, completion: completion)
                    return
                }
                completion(result)
            }
        }
    }

    /// 다시 걸어 볼 값어치가 있는 실패인가. 키가 없거나 글이 비었으면 몇 번을 걸어도 같다.
    private static func worthRetrying(_ error: Error) -> Bool {
        if case Failure.badResponse(let code, _) = error {
            return code == 429 || code == 500 || code == 502 || code == 503 || code == 504
        }
        if case Failure.noAPIKey = error { return false }
        if case Failure.emptyAnswer = error { return false }
        // 시간 초과·연결 끊김 같은 네트워크 오류는 다시 걸어 본다.
        return (error as NSError).domain == NSURLErrorDomain
    }

    /// 고른 회사로 보낸다. 회의록은 글이 길어서(48분이면 4만 자) 받아쓰기 쪽 클라이언트를
    /// 그대로 쓰지 않는다 — 거기는 출력이 2048 토큰으로 묶여 있어 중간에 잘린다.
    private static func call(_ transcript: String, speakersKnown: Bool,
                             backend: Prefs.Backend, model: String,
                             completion: @escaping (Swift.Result<String, Error>) -> Void) {
        let system = (speakersKnown ? speakerNote : "") + instruction
        let user = "<회의록>\n\(transcript)\n</회의록>"
        switch backend {
        case .openai:
            // ⚠️ 넉넉히 준다. 추론 모델은 **생각에 토큰을 먼저 쓴다** — 2026-09-30 실측에서
            //    48분 회의에 3,000 을 주니 2,048 을 생각에 쓰고 본문이 **비어서** 왔다.
            //    실제 소모는 3,365 였다. 예약이 커도 쓴 만큼만 청구되니 크게 잡는다.
            GPTClient.shared.send(system: system, user: user, model: model,
                                  maxTokens: 16000, timeout: 300) { completion($0.map(tidy)) }
        case .api:
            // ⚠️ OpenAI 와 같은 이유로 넉넉히 준다. Claude 도 `thinking` 블록이 먼저 나오고
            //    그게 `max_tokens` 를 먹는다 — 2026-09-30 실측에서 8,192 중 **6,374 가 생각**이었고,
            //    앱에서 돌렸을 땐 생각하다 한도에 걸려 본문이 0자로 왔다.
            ClaudeClient.shared.raw(system: system, user: user, model: model,
                                    maxTokens: 24000, timeout: 300) { completion($0.map(tidy)) }
        default:
            callGemini(transcript, speakersKnown: speakersKnown, model: model, completion: completion)
        }
    }

    private static func callGemini(_ transcript: String, speakersKnown: Bool, model: String,
                                   completion: @escaping (Swift.Result<String, Error>) -> Void) {
        guard let key = KeychainStore.read(.gemini), !key.isEmpty else {
            completion(.failure(Failure.noAPIKey))
            return
        }
        guard let url = URL(string:
            "https://generativelanguage.googleapis.com/v1beta/models/\(model):generateContent") else {
            completion(.failure(Failure.badResponse(0, "주소를 만들지 못했습니다.")))
            return
        }

        let body: [String: Any] = [
            "contents": [["parts": [["text": "\(speakersKnown ? speakerNote : "")\(instruction)\n\n<회의록>\n\(transcript)\n</회의록>"]]]],
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
