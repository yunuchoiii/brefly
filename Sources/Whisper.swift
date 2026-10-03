import AVFoundation

/// whisper.cpp 로 소리 파일을 받아쓴다. 회의록처럼 **긴 녹음**을 한꺼번에 처리하는 쪽에만 쓴다.
/// 짧은 받아쓰기(`fn⌃`)는 지금처럼 애플 인식기를 쓴다 — 말하는 중에 실시간으로 글자가 나와야 하고,
/// 모델을 받을 필요도 없기 때문이다.
///
/// 애플 인식기 대신 이걸 쓰는 이유는 속도다. 35분짜리 한국어 녹음으로 잰 값이다(2026-09-29).
///
///     애플 서버, 통째로   22분 넘게, 못 끝냄
///     애플 서버, 5분×7    274초   10,515자
///     whisper.cpp turbo   124초   16,399자
///
/// 두 배 빠른데 1.5배 더 받아썼다. 애플 인식은 긴 파일에서 비선형으로 느려진다.
enum Whisper {

    /// 낱말 묶음 하나. 화자 분리 구간과 겹쳐 맞추려면 시각이 필요하다.
    struct Segment {
        let text: String
        let start: Double
        let end: Double
        /// 누가 말했는지. 화상 회의처럼 트랙이 갈려 있을 때만 채워진다(`"나"` / `"상대"`).
        /// 받아쓰기 자체는 화자를 모른다 — 채널이 알려 주는 것이다.
        var speaker: String? = nil
    }

    enum Failure: LocalizedError {
        case cancelled
        case modelMissing(URL)
        case modelUnreadable(URL)
        case audioUnreadable(URL)
        case failed(Int32)

        var errorDescription: String? {
            switch self {
            case .cancelled:                return "취소했습니다."
            case .modelMissing(let url):    return "받아쓰기 모델이 없습니다: \(url.lastPathComponent)"
            case .modelUnreadable(let url): return "받아쓰기 모델을 열지 못했습니다: \(url.lastPathComponent)"
            case .audioUnreadable(let url): return "소리 파일을 읽지 못했습니다: \(url.lastPathComponent)"
            case .failed(let code):         return "받아쓰기에 실패했습니다 (코드 \(code))"
            }
        }
    }

    /// 진행률 콜백을 C 로 넘기기 위한 상자. C 함수 포인터는 Swift 클로저를 직접 못 받으므로
    /// 상자를 user_data 로 넘기고 콜백 안에서 꺼내 쓴다.
    private final class ProgressBox {
        let report: (Double) -> Void
        init(_ report: @escaping (Double) -> Void) { self.report = report }
    }

    /// whisper.cpp 가 요구하는 형식. `MeetingRecorder` 가 처음부터 이 형식으로 남기므로 회의 녹음은 변환이 없다.
    static let sampleRate = 16_000.0

    /// ⚠️ **`initial_prompt` 로 용어를 미리 알려 주지 말 것.** 그럴듯해 보이지만 한국어 긴 녹음에서는
    ///    오히려 망가진다. 같은 20분 녹음으로 잰 값이다(2026-09-29).
    ///
    ///      안 넣음                   대원CTS 5번, 9,871자
    ///      넣고 carry_initial_prompt  대원CTS 0번(대형 CTS·대한민국으로 들림), 9,557자
    ///      넣고 carry 끔              대원CTS 0번, 모의해킹도 0번, 10,367자
    ///
    ///    창마다 낱말 목록을 밀어 넣으면 앞뒤 문맥을 잃고, 첫 창에만 넣어도 전체가 흔들렸다.
    ///    용어 교정은 받아쓴 **뒤에** `Glossary.apply` 로 한다 — 그쪽은 실측으로 다 통했다.
    /// - Parameter onProgress: 0~1. 회의록은 1~2분이 걸려서 진행률이 없으면 멈춘 줄 안다.
    /// 디코더가 같은 문장에 갇히지 않게 하는 손잡이들. 기본값은 실측으로 정한다(`--whisper` 로 A/B).
    struct Guards {
        /// 앞 구간의 글을 다음 구간의 힌트로 넘길지. `true` 면 **안 넘긴다.**
        var noContext: Bool
        /// 결과가 망가져 보일 때 온도를 올려 다시 뽑는 폭. 0 이면 다시 뽑지 않는다.
        var temperatureInc: Float
        /// 글자 분포가 이보다 단조로우면(= 같은 말 반복) 다시 뽑는다.
        var entropyThreshold: Float
        /// ⚠️ **whisper.cpp 기본값 그대로다.** 바꿔 보고 되돌렸다(2026-10-02 실측, `--whisper` A/B).
        ///
        ///     no_context = true        효과 **0** — 두 트랙 모두 바이트까지 같은 결과
        ///     temp_inc .4 / entropy 2.8  면접 마이크 되풀이 26% → 1%  (좋아짐)
        ///                                유튜브 시스템 되풀이 22% → 49% (나빠짐)
        ///
        /// 온도를 올려 다시 뽑으면 **다른 환청**이 나올 뿐이라 트랙에 따라 복불복이다.
        /// 되풀이는 디코더를 돌려 고치지 않고 `collapseRuns` 가 뒤에서 걷어낸다.
        static let `default` = Guards(noContext: false, temperatureInc: 0.2, entropyThreshold: 2.4)
        static let legacy = Guards(noContext: false, temperatureInc: 0.2, entropyThreshold: 2.4)
    }

    static func transcribe(audio: URL, model: URL, language: String = "ko",
                           threads: Int32 = 8,
                           guards: Guards = .default,
                           vadModel: URL? = nil,
                           cancel: CancelToken? = nil,
                           onProgress: ((Double) -> Void)? = nil) throws -> [Segment] {
        guard FileManager.default.fileExists(atPath: model.path) else { throw Failure.modelMissing(model) }
        let samples = try monoSamples(audio)

        var contextParams = whisper_context_default_params()
        // 정적으로 이어 넣었으므로 백엔드(Metal 등)가 저절로 등록된다. 동적 라이브러리로 쓸 때는
        // ggml_backend_load_all_from_path() 를 직접 불러야 하고, 안 부르면 모델을 여는 순간 죽는다.
        contextParams.use_gpu = true
        guard let context = whisper_init_from_file_with_params(model.path, contextParams) else {
            throw Failure.modelUnreadable(model)
        }
        defer { whisper_free(context) }

        var params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY)
        params.print_progress = false
        params.print_realtime = false
        params.print_timestamps = false
        params.print_special = false
        params.translate = false
        params.n_threads = threads
        // 진행 표시를 끄지 않으면 whisper.cpp 가 stderr 로 줄줄이 찍는다.
        params.no_timestamps = false

        // ⚠️ **같은 문장이 수백 번 반복되는 것**을 막는 손잡이들이다. 2026-10-02 실측에서
        //    16,675자짜리 회의록에 같은 줄이 251번 들어 있었다. 유튜브처럼 말이 아닌 소리가
        //    섞이면 디코더가 한 문장에 갇히고, 기본값은 앞 구간의 글을 다음 구간 힌트로
        //    넘기기 때문에(`no_context = false`) 한 번 갇히면 끝까지 끌고 간다.
        params.no_context = guards.noContext
        params.temperature_inc = guards.temperatureInc
        params.entropy_thold = guards.entropyThreshold

        // 멈추라는 표를 C 쪽에 넘긴다. whisper 는 창을 하나 끝낼 때마다 물어본다.
        if let cancel {
            params.abort_callback = { userData in
                guard let userData else { return false }
                return Unmanaged<CancelToken>.fromOpaque(userData).takeUnretainedValue().isCancelled
            }
            params.abort_callback_user_data = Unmanaged.passUnretained(cancel).toOpaque()
        }

        let progressBox = onProgress.map { ProgressBox($0) }
        if let progressBox {
            params.progress_callback = { _, _, percent, userData in
                guard let userData else { return }
                Unmanaged<ProgressBox>.fromOpaque(userData).takeUnretainedValue().report(Double(percent) / 100)
            }
            params.progress_callback_user_data = Unmanaged.passUnretained(progressBox).toOpaque()
        }

        // ⚠️ C 쪽은 이 포인터를 붙잡고 있는다. 문자열을 그 자리에서 만들어 넘기면 이미 사라진 뒤를 가리킨다.
        // VAD 를 켜면 말이 있는 구간만 골라 받아쓴다. 경로 문자열도 C 쪽이 붙잡으므로 수명을 늘려 둔다.
        let vadPath = vadModel?.path ?? ""
        if vadModel != nil {
            params.vad = true
            params.vad_params = whisper_vad_default_params()
        }
        Log.write("받아쓰기 시작 — \(audio.lastPathComponent), VAD \(vadModel == nil ? "끔(모델 없음)" : "켬")")
        return try vadPath.withCString { vadPointer in
        if vadModel != nil { params.vad_model_path = vadPointer }
        return try language.withCString { languagePointer in
            params.language = languagePointer
            // ⚠️ 상자를 붙잡아 둔다. 중간에 풀려나면 콜백이 사라진 객체를 가리킨다.
            let code = withExtendedLifetime((progressBox, cancel)) {
                whisper_full(context, params, samples, Int32(samples.count))
            }
            // 멈춘 것도 whisper 는 실패로 돌려준다. 사용자가 누른 것이면 오류로 보이면 안 된다.
            if cancel?.isCancelled == true { throw Failure.cancelled }
            guard code == 0 else { throw Failure.failed(code) }

            var segments: [Segment] = []
            for i in 0..<whisper_full_n_segments(context) {
                guard let raw = whisper_full_get_segment_text(context, i) else { continue }
                let text = String(cString: raw).trimmingCharacters(in: .whitespaces)
                guard !text.isEmpty else { continue }
                // whisper 의 시각 단위는 10밀리초다.
                segments.append(Segment(text: text,
                                        start: Double(whisper_full_get_segment_t0(context, i)) / 100,
                                        end: Double(whisper_full_get_segment_t1(context, i)) / 100))
            }
            return collapseRuns(segments)
        }
        }
    }

    /// 같은 말이 **연달아** 쏟아지는 것을 걷어낸다.
    ///
    /// whisper 는 말이 아닌 소리(음악·유튜브)나 긴 침묵에서 한 문장에 갇혀 수백 번을 쏟는다.
    /// 2026-10-02 실측 — 실제 회의 녹음에서 나온 것들이다.
    ///
    ///     "상대: 한 번에 있던 학생들은"   251회   (유튜브를 틀어 둔 화상 면접)
    ///     "아, 혈압이 너무 올라가서."     242회
    ///     "나: -끝났습니다."             101회
    ///
    /// ⚠️ **연달아 나올 때만** 버린다. 흩어져 나오는 "네."·"맞아요" 는 진짜 대답이다 —
    ///    같은 녹음에서 11번 흩어져 나온 "네." 는 그대로 남는 것을 확인했다.
    /// ⚠️ 하나는 남긴다. 통째로 지우면 그 자리에 무슨 소리가 있었는지조차 사라진다.
    static func collapseRuns(_ segments: [Segment], keep: Int = 2) -> [Segment] {
        var out: [Segment] = []
        var run = 0
        var last: String?
        for s in segments {
            let key = s.text.filter { !$0.isWhitespace && !$0.isPunctuation }
            if key == last { run += 1 } else { run = 1; last = key }
            if run <= keep { out.append(s) }
        }
        if out.count < segments.count {
            Log.write("되풀이 걷어냄 — 구간 \(segments.count)개 → \(out.count)개")
        }
        return out
    }

    /// 어떤 소리 파일이든 16kHz 모노 실수 배열로 만든다. 이미 그 형식이면 그대로 읽는다.
    private static func monoSamples(_ url: URL) throws -> [Float] {
        guard let file = try? AVAudioFile(forReading: url) else { throw Failure.audioUnreadable(url) }
        let source = file.processingFormat
        guard let target = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: 1),
              let input = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(file.length))
        else { throw Failure.audioUnreadable(url) }
        try file.read(into: input)

        if source.sampleRate == sampleRate && source.channelCount == 1 {
            guard let channel = input.floatChannelData?[0] else { throw Failure.audioUnreadable(url) }
            return Array(UnsafeBufferPointer(start: channel, count: Int(input.frameLength)))
        }

        guard let converter = AVAudioConverter(from: source, to: target) else { throw Failure.audioUnreadable(url) }
        let capacity = AVAudioFrameCount(Double(input.frameLength) * sampleRate / source.sampleRate) + 4096
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else {
            throw Failure.audioUnreadable(url)
        }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true
            status.pointee = .haveData
            return input
        }
        guard error == nil, let channel = output.floatChannelData?[0] else { throw Failure.audioUnreadable(url) }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}
