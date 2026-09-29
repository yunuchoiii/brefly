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
    static func transcribe(audio: URL, model: URL, language: String = "ko",
                           threads: Int32 = 8,
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
            return segments
        }
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
