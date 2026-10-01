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
        /// ⚠️ `var` 다. `## 제목` 을 뽑은 뒤 본문에서 떼어 내려고 한 번 고쳐 쓴다.
        var notes: String
        /// 시각이 붙은 낱말 묶음. 원문 탭이 "몇 분에 무슨 말을 했는지" 보여 주는 데 쓴다.
        /// 나중에 화자 구분이 들어오면 이 시각에 화자 구간을 겹쳐 맞춘다.
        let segments: [Whisper.Segment]
        let transcribeSeconds: Double
        let summarizeSeconds: Double
        /// 실제로 요약한 회사와 모델. AUTO 는 회사를 오가므로 결과만 보고는 알 수 없다.
        /// 예: `("ChatGPT — 정확", "gpt-5.5")`
        var usedModel: (label: String, name: String)?
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
        /// 받아쓰긴 했는데 말이라 할 것이 없다. 오류가 아니라 "남길 것이 없다"는 뜻이다.
        case noSpeech

        var errorDescription: String? {
            switch self {
            case .noAPIKey:
                return "회의록을 만들려면 Gemini 키가 필요합니다. 설정 > AI 모델에서 넣어 주세요."
            case .badResponse(let code, let body):
                return "요약에 실패했습니다 (\(code)). \(body.prefix(140))"
            case .emptyAnswer:
                return "요약이 비어 있습니다. 녹음이 너무 짧거나 말소리가 없는 것 같습니다."
            case .noSpeech:
                return "말한 내용이 없어 회의록을 만들지 않았습니다."
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

    /// 회의록 지시문. 받아쓰기 프롬프트와 완전히 따로 둔다.
    ///
    /// **지어내지 말라**를 가장 앞에 둔다. 긴 글을 넣으면 모델이 회의록의 꼴을 갖추려고
    /// 없는 담당자와 마감을 채워 넣는다. 회의록은 그러면 못 쓴다 — 틀린 회의록은 없느니만 못하다.
    ///
    /// `detail` 은 **담는 항목과 깊이**를 바꾼다. 분량을 늘리라고 시키지 않는다 —
    /// 그렇게 하면 모델이 빈 자리를 추측으로 메운다. 자세한 단계일수록 "원문에 있는 것을 더
    /// 많이 담되 없는 것은 보태지 말라"를 **한 번 더** 못 박는다.
    static func instruction(_ detail: Prefs.MeetingDetail) -> String {
        let head = """
        아래 <회의록> 안은 회의를 받아쓴 것이다. 이것을 회의록으로 정리한다.

        가장 중요한 규칙: **원문에 없는 것을 절대 만들지 않는다.**
        - 담당자와 마감은 원문에서 말한 것만 적는다. 없으면 그 항목을 비운다.
        - "누가 말했는지"는 알 수 없다. 화자를 추측해 적지 않는다.
        - 받아쓰기라 잘못 들린 낱말이 섞여 있다. 앞뒤로 뜻이 통하는 쪽으로 읽되, 확신이 없으면 그대로 둔다.

        다음 차례로 쓴다. 해당하는 내용이 없는 항목은 통째로 뺀다.

        ## 제목
        목록에서 한눈에 알아볼 이름. 20자 안쪽으로 짧게.
        ⚠️ **반드시 명사로 끝낸다** — "…논의", "…확정", "…점검", "…일정 조율".
        "…했다", "…하기로 했다" 처럼 문장으로 맺지 않는다. 마침표도 찍지 않는다.

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
        """

        let body: String
        switch detail {
        case .brief:
            body = """

            여기까지만 쓴다. '논의한 것'과 '다음에 볼 것'은 **쓰지 않는다.**
            '결정된 것'과 '할 일'은 가장 중요한 것 세 개까지만 남긴다.
            """
        case .short:
            body = """

            ## 논의한 것
            - 무엇을 이야기했는지 한 줄씩. 세 개까지.

            '다음에 볼 것'은 쓰지 않는다.
            """
        case .normal:
            body = """

            ## 논의한 것
            - 결론이 안 난 것, 의견이 갈린 것. 왜 갈렸는지까지.

            ## 다음에 볼 것
            - 다음 회의나 후속으로 넘긴 것.
            """
        case .detailed:
            body = """

            ## 논의한 것
            - 결론이 안 난 것, 의견이 갈린 것. 왜 갈렸는지까지.
            - 어느 쪽이 무엇을 근거로 들었는지 하위 불릿으로 받친다.

            ## 다음에 볼 것
            - 다음 회의나 후속으로 넘긴 것.

            이 단계에서는 **개수를 줄이지 않는다.** 원문에서 오간 숫자·날짜·금액·이름·제품명을
            빠뜨리지 말고 그대로 적는다.
            ⚠️ 자세히 쓰라는 것은 **원문에 있는 것을 더 많이 담으라**는 뜻이다. 원문에 없는
            배경 설명이나 추측을 보태라는 뜻이 **아니다.** 담을 것이 없으면 짧게 끝낸다.
            """
        case .full:
            body = """

            ## 논의한 것
            - 결론이 안 난 것, 의견이 갈린 것. 왜 갈렸는지까지.
            - 어느 쪽이 무엇을 근거로 들었는지 하위 불릿으로 받친다.

            ## 다음에 볼 것
            - 다음 회의나 후속으로 넘긴 것.

            ## 회의 흐름
            - 이야기가 오간 차례를 처음부터 끝까지 훑는다. 주제가 바뀐 자리마다 한 불릿.
            - 원문에서 쓴 표현을 되도록 그대로 쓴다. 바꿔 말하면 뜻이 틀어진다.

            이 단계에서는 **개수를 줄이지 않는다.** 원문에서 오간 숫자·날짜·금액·이름·제품명을
            빠뜨리지 말고 그대로 적는다.
            ⚠️ 가장 자세한 단계지만 **지어내기는 여전히 금지다.** 분량을 채우려고 원문에 없는
            말을 보태면 회의록을 통째로 못 쓰게 된다. 원문이 짧으면 결과도 짧아야 맞다.
            """
        }

        return head + body + """


        문체는 '~다'로 쓴다. 인사말·잡담·같은 말 반복은 버린다.
        """
    }

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
                                              language: language,
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
            guard !isNoSpeech(transcript, segments: segments) else {
                Log.write("회의록 건너뜀 — 말이 없다 (받아쓴 글 \(transcript.count)자)")
                completion(.failure(Failure.noSpeech))
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

    /// 받아쓸 언어. 설정의 인식 언어(`ko-KR`)에서 앞 두 글자를 쓴다 — whisper 는 `ko` 꼴을 받는다.
    ///
    /// ⚠️ 2026-10-02 까지 `"ko"` 로 **고정돼 있었다.** 설정은 한국어·영어·일본어 셋을 주는데
    ///    회의록만 그걸 안 봤다. 실측으로는 영어 음성을 `ko` 라고 알려 줘도 영어로 받아 적었지만
    ///    (large-v3-turbo 는 자동 판별이 세다), 설정이 있는데 안 보는 것은 그 자체로 고장이다.
    private static var language: String { String(Prefs.localeID.prefix(2)) }

    /// 받아쓰긴 했지만 **말이라 할 것이 없는** 녹음인지 본다. 여기서 걸리면 회의록을 만들지도,
    /// 기록에 남기지도 않는다.
    ///
    /// whisper 는 조용한 구간이나 잡음에서 말을 **지어낸다.** 실제로 나온 것들이다.
    ///
    ///     "다음 영상에서 만나요. 다음 영상에서 만나요. 다음 영상에서 만나요."   (38자)
    ///     "아 으 으 으 으 … 으"                                          (57자)
    ///
    /// ⚠️ 짧은 **진짜** 회의를 같이 버리면 안 되므로 조건을 **겹쳐서** 건다. 실측한 회의 12건의
    ///    받아쓴 글 길이는 이렇게 갈린다(2026-10-01).
    ///
    ///     진짜  150 · 214 · 509 · 608 · 1440 · 1571 · 2088 · 2466 · 6007 · 12408자
    ///     지어낸 것  38 · 57자
    ///
    ///    길이만으로 자르지 않는다 — 30초짜리 진짜 회의가 80자일 수 있다. "짧다" **그리고**
    ///    "같은 말만 되풀이한다 / 쓰인 음절이 몇 개 안 된다"일 때만 버린다.
    static func isNoSpeech(_ transcript: String, segments: [Whisper.Segment]) -> Bool {
        let letters = transcript.filter { !$0.isWhitespace && !$0.isPunctuation }
        if letters.count <= 30 { return true }
        guard letters.count < 100 else { return false }

        // 화자 이름과 불릿은 내용이 아니다. 빼고 센다.
        let spoken = Set(segments.map {
            $0.text.replacingOccurrences(of: #"^\s*(나|상대)\s*:\s*|^\s*-\s*"#,
                                         with: "", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }).filter { !$0.isEmpty }

        // 같은 말만 되풀이했다. ("다음 영상에서 만나요." ×3)
        if spoken.count == 1, segments.count >= 2 { return true }
        // 쓰인 음절이 몇 개 안 된다. ("아 으 으 으 …" → 아, 으 둘뿐)
        if Set(letters).count < 10 { return true }
        return false
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
                          transcribeSeconds: transcribeSeconds, summarizeSeconds: elapsed,
                          usedModel: lastUsed)
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
    /// 사용자가 녹음 중에 찍은 중요 구간(녹음 시작 기준 초). 그 시각에 걸친 말을 뽑아
    /// 모델에 따로 짚어 준다.
    ///
    /// ⚠️ 원문에 끼워 넣지 않고 **따로 붙인다.** 본문 안에 표시를 섞으면 모델이 그 표시를
    ///    결과에 그대로 베껴 쓴다(2026-09-29 에 "김 과장" 예시가 담당자로 올라간 것과 같은 함정).
    static func highlightNote(_ ranges: [(start: Double, end: Double)],
                              segments: [Whisper.Segment]) -> String {
        guard !ranges.isEmpty else { return "" }
        var picked: [String] = []
        for r in ranges {
            let inside = segments
                .filter { $0.start < r.end && $0.end > r.start }
                .map(\.text)
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespaces)
            if !inside.isEmpty { picked.append(inside) }
        }
        guard !picked.isEmpty else { return "" }
        return """
            말한 사람이 녹음 중에 **중요하다고 직접 표시한 대목**이다. 아래 말들이 회의록에
            빠지지 않게 하고, 결정된 것이나 할 일에 해당하면 반드시 적는다.
            다만 여기 없는 내용을 빼라는 뜻은 아니다.

            \(picked.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n"))


            """
    }

    static func makeFromTracks(mic: URL, system: URL?, recordedAt: Date,
                               highlights: [(start: Double, end: Double)] = [],
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
                    audio: mic, model: model, language: language, cancel: cancel,
                    onProgress: { onProgress(Progress(stage: .transcribing,
                                                      fraction: hasSystem ? $0 / 2 : $0)) })
                var systemSegments: [Whisper.Segment] = []
                if let system {
                    systemSegments = try Whisper.transcribe(
                        audio: system, model: model, language: language, cancel: cancel,
                        onProgress: { onProgress(Progress(stage: .transcribing, fraction: 0.5 + $0 / 2)) })
                }

                // 용어 치환은 합친 글에 한 번만 건다.
                let merged = Glossary.apply(to: EchoFilter.merge(mic: micSegments, system: systemSegments))
                let transcribeSeconds = Date().timeIntervalSince(started)
                if cancel?.isCancelled == true {
                    completion(.failure(Whisper.Failure.cancelled))
                    return
                }
                // ⚠️ 화면에 보여 줄 구간은 **시각순으로 엮고 화자를 붙여** 둔다.
                //    전에는 `micSegments + systemSegments` 로 이어 붙여서, 원문 탭이
                //    내 말 전부 → 상대 말 전부 순서로 나오고 시각이 중간에 0 으로 되돌아갔다.
                //    에코도 안 걸러져서 상대 말이 두 번 보였다.
                let shown = EchoFilter.labelled(mic: micSegments, system: systemSegments)
                // ⚠️ `make` 와 **따로** 건다. 두 구현이 나뉘어 있어서, 한쪽에만 넣으면 실제
                //    회의 녹음(이쪽)은 그냥 지나간다. 2026-10-01 에 한 번 그랬다.
                guard !isNoSpeech(merged, segments: shown) else {
                    Log.write("회의록 건너뜀 — 말이 없다 (받아쓴 글 \(merged.count)자)")
                    completion(.failure(Failure.noSpeech))
                    return
                }
                onTranscript?(merged, shown)
                onProgress(Progress(stage: .summarizing, fraction: nil))
                let summarizeStarted = Date()
                let note = highlightNote(highlights, segments: shown)
                if !note.isEmpty { Log.write("중요 표시 \(highlights.count)곳을 요약에 짚어 준다") }
                summarize(merged, speakersKnown: hasSystem, highlightNote: note) { result in
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
    /// - Parameter detail: 안 주면 설정값을 쓴다. "다시 요약"은 그때 고른 단계를 넣는다.
    static func summarizeOnly(_ transcript: String, speakersKnown: Bool = false,
                              detail: Prefs.MeetingDetail = Prefs.meetingDetail,
                              completion: @escaping (Swift.Result<String, Error>) -> Void) {
        summarize(transcript, speakersKnown: speakersKnown, detail: detail, completion: completion)
    }

    /// 마지막으로 성공한 회사·모델. "다시 요약" 뒤에 표시를 갱신할 때 쓴다.
    static var lastUsedModel: (label: String, name: String)? { lastUsed }

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
                                  highlightNote: String = "",
                                  detail: Prefs.MeetingDetail = Prefs.meetingDetail,
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
        tryChoice(transcript, speakersKnown: speakersKnown, highlightNote: highlightNote, detail: detail,
                  chain: chain, index: 0, completion: completion)
    }

    /// 회사를 하나씩 내려가며 시도한다. 한 회사 안에서는 `attempt` 가 모델과 재시도를 맡는다.
    /// 마지막으로 성공한 회사·모델. `attempt` 가 모델을 바꿔 가며 걸어서 결과만으로는 알 수 없다.
    private static var lastUsed: (label: String, name: String)?

    private static func tryChoice(_ transcript: String, speakersKnown: Bool, highlightNote: String,
                                  detail: Prefs.MeetingDetail,
                                  chain: [Prefs.Choice], index: Int,
                                  completion: @escaping (Swift.Result<String, Error>) -> Void) {
        let chosen = chain[index]
        let models = Prefs.modelNames(chosen.backend, chosen.tier)
        Log.write("회의록 요약: \(chosen.backend.shortTitle) \(chosen.tier.suffix) — \(models.first ?? "?")")
        attempt(transcript, speakersKnown: speakersKnown, highlightNote: highlightNote, detail: detail,
                backend: chosen.backend, models: models.isEmpty ? [Prefs.geminiModel] : models,
                modelIndex: 0, tryIndex: 0) { result in
            if case .failure(let error) = result, index + 1 < chain.count {
                Log.write("회의록 \(chosen.backend.shortTitle) 실패 — \(chain[index + 1].title) 로 넘어감: "
                          + error.localizedDescription.prefix(80))
                tryChoice(transcript, speakersKnown: speakersKnown, highlightNote: highlightNote,
                          detail: detail, chain: chain, index: index + 1, completion: completion)
                return
            }
            completion(result)
        }
    }

    /// 같은 모델로 `retryDelays` 만큼 물러서며 다시 걸고, 다 쓰면 다음 모델로 넘어간다.
    private static func attempt(_ transcript: String, speakersKnown: Bool, highlightNote: String = "",
                                detail: Prefs.MeetingDetail,
                                backend: Prefs.Backend, models: [String],
                                modelIndex: Int, tryIndex: Int,
                                completion: @escaping (Swift.Result<String, Error>) -> Void) {
        let model = models[min(modelIndex, models.count - 1)]
        call(transcript, speakersKnown: speakersKnown, highlightNote: highlightNote, detail: detail,
             backend: backend, model: model) { result in
            switch result {
            case .success:
                // 어느 것이 뽑았는지 남긴다. 결과 창의 "요약 정보"가 이걸 보여 준다.
                lastUsed = (backend.shortTitle, model)
                if modelIndex > 0 || tryIndex > 0 { Log.write("요약 성공 — \(model), \(tryIndex + 1)번째 시도") }
                completion(result)
            case .failure(let error):
                guard worthRetrying(error) else { completion(result); return }
                if tryIndex < retryDelays.count {
                    let wait = retryDelays[tryIndex]
                    Log.write("요약 재시도 — \(model), \(wait)초 뒤 (\(error.localizedDescription.prefix(60)))")
                    DispatchQueue.global().asyncAfter(deadline: .now() + wait) {
                        attempt(transcript, speakersKnown: speakersKnown, highlightNote: highlightNote,
                                detail: detail,
                                backend: backend, models: models,
                                modelIndex: modelIndex, tryIndex: tryIndex + 1, completion: completion)
                    }
                    return
                }
                if modelIndex + 1 < models.count {
                    Log.write("요약 모델 바꿈 — \(model) → \(models[modelIndex + 1])")
                    attempt(transcript, speakersKnown: speakersKnown, highlightNote: highlightNote,
                            detail: detail,
                            backend: backend, models: models,
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
    private static func call(_ transcript: String, speakersKnown: Bool, highlightNote: String = "",
                             detail: Prefs.MeetingDetail,
                             backend: Prefs.Backend, model: String,
                             completion: @escaping (Swift.Result<String, Error>) -> Void) {
        let system = (speakersKnown ? speakerNote : "") + highlightNote + instruction(detail)
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
            callGemini(transcript, speakersKnown: speakersKnown, detail: detail,
                       model: model, completion: completion)
        }
    }

    private static func callGemini(_ transcript: String, speakersKnown: Bool,
                                   detail: Prefs.MeetingDetail, model: String,
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
            "contents": [["parts": [["text": "\(speakersKnown ? speakerNote : "")\(instruction(detail))\n\n<회의록>\n\(transcript)\n</회의록>"]]]],
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
