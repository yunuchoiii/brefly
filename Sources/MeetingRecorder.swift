import AVFoundation

/// 회의 녹음. 마이크(나)와 시스템 소리(상대)를 **따로** 모아 둔다.
///
/// 두 갈래를 섞지 않는 것이 핵심이다. 화상회의에서는 이 갈래가 곧 화자 구분이라,
/// 섞어 버리면 화자 분리 모델을 돌려야 얻을 수 있는 정보를 스스로 버리는 셈이 된다.
///
/// ⚠️ **이 앱은 원래 목소리를 디스크에 남기지 않는다**(`IntonationTracker` 참고).
///    회의록은 그 원칙의 의도적인 예외다. 화자 분리에 녹음 전체가 필요하고, 요약이 끝난 뒤에도
///    사용자가 원문을 다시 듣고 싶어 하기 때문이다. 받아쓰기(`fn⌃`)는 지금처럼 아무것도 남기지 않는다.
final class MeetingRecorder {

    /// 16kHz 모노. whisper.cpp 와 sherpa-onnx 가 그대로 받는 형식이라 나중에 변환할 일이 없다.
    /// 48kHz 스테레오 float32 로 두면 1시간 회의에 2.6GB 인데, 이 형식은 220MB 다.
    static let sampleRate = 16_000.0

    struct Session {
        let directory: URL
        let mic: URL
        let system: URL
        let startedAt: Date
    }

    private(set) var session: Session?
    private let engine = AVAudioEngine()
    private let systemAudio = SystemAudioRecorder()
    private var micTrack: TrackWriter?
    private var systemTrack: TrackWriter?

    /// 시스템 소리를 못 잡았을 때의 이유. 화면 기록 권한이 없으면 여기에 담기고,
    /// 녹음 자체는 마이크만으로 이어 간다 — 대면 회의는 그것으로 충분하다.
    private(set) var systemAudioError: Error?

    /// ⚠️ 쓴 조각 수는 **멈춘 뒤에도 읽는다.** writer 를 비우면서 세면 0 이 나온다(한 번 그렇게 만들었다).
    ///    그래서 writer 가 아니라 여기에 남긴다.
    private(set) var micBuffers = 0
    private(set) var systemBuffers = 0

    // MARK: - 시작과 멈춤

    func start() async throws -> Session {
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd-HHmmss"
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Brefly/meetings/\(stamp.string(from: Date()))",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let session = Session(directory: dir,
                              mic: dir.appendingPathComponent("mic.wav"),
                              system: dir.appendingPathComponent("system.wav"),
                              startedAt: Date())

        micBuffers = 0
        systemBuffers = 0
        micTrack = try TrackWriter(url: session.mic)
        let input = engine.inputNode
        // ⚠️ 스피커로 나가는 상대 목소리가 **마이크로 되돌아 들어온다**(실측: 두 갈래를 따로 받아썼더니
        //    같은 문장이 양쪽에 다 있었다). 그대로 두면 회의록에 모든 말이 두 번 적힌다.
        //    voice processing 을 켜면 macOS 가 에코를 지운다. 엔진을 켜기 전에 켜야 한다.
        //    이어폰을 쓰면 애초에 안 생기는 문제지만, 노트북 스피커로 회의하는 사람이 더 많다.
        do {
            try input.setVoiceProcessingEnabled(true)
        } catch {
            Log.write("회의 녹음: 에코 제거를 못 켰다 — \(error.localizedDescription). 스피커로 들으면 상대 말이 두 번 적힌다.")
        }
        let format = input.inputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            self?.micTrack?.write(buffer)
        }
        engine.prepare()
        try engine.start()

        // 시스템 소리는 실패해도 회의를 접지 않는다. 대면 회의라면 애초에 필요 없다.
        do {
            systemTrack = try TrackWriter(url: session.system)
            systemAudio.onBuffer = { [weak self] buffer in self?.systemTrack?.write(buffer) }
            try await systemAudio.start()
        } catch {
            systemAudioError = error
            systemTrack = nil
            Log.write("회의 녹음: 시스템 소리를 못 잡는다 — \(error.localizedDescription). 마이크만 남긴다.")
        }

        self.session = session
        Log.write("회의 녹음 시작 — \(dir.lastPathComponent)")
        return session
    }

    @discardableResult
    func stop() async -> Session? {
        guard let session else { return nil }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        await systemAudio.stop()
        micTrack?.close()
        systemTrack?.close()
        micBuffers = micTrack?.written ?? 0
        systemBuffers = systemTrack?.written ?? 0
        let minutes = Date().timeIntervalSince(session.startedAt) / 60
        Log.write("회의 녹음 멈춤 — \(String(format: "%.1f", minutes))분, 마이크 \(micBuffers)조각, 시스템 \(systemBuffers)조각")
        micTrack = nil
        systemTrack = nil
        self.session = nil
        return session
    }
}

/// 들어오는 소리를 16kHz 모노로 바꿔 WAV 에 쓴다.
///
/// 마이크는 48kHz, 시스템 소리는 48kHz 스테레오로 들어온다. 둘 다 형식이 다르고 그대로 쓰면
/// 용량이 열 배가 넘으므로, 받는 자리에서 바로 줄인다. `AVAudioFile` 은 표본율이 다르면
/// 그냥 던지므로 `AVAudioConverter` 로 직접 맞춰야 한다.
private final class TrackWriter {

    private let file: AVAudioFile
    /// 파일에 써 넣는 형식. 32비트 실수로 받아서 `AVAudioFile` 이 16비트 정수로 낮춘다.
    private let target: AVAudioFormat
    private var converter: AVAudioConverter?
    private(set) var written = 0

    init(url: URL) throws {
        guard let target = AVAudioFormat(standardFormatWithSampleRate: MeetingRecorder.sampleRate, channels: 1) else {
            throw NSError(domain: "TrackWriter", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "형식을 만들지 못했습니다"])
        }
        self.target = target
        self.file = try AVAudioFile(forWriting: url, settings: [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: MeetingRecorder.sampleRate,
            AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false,
            AVLinearPCMIsBigEndianKey: false,
        ])
    }

    /// 오디오 스레드에서 불린다. 무거운 일을 하면 소리가 끊긴다.
    func write(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0 else { return }
        if converter == nil || converter?.inputFormat != buffer.format {
            converter = AVAudioConverter(from: buffer.format, to: target)
        }
        guard let converter else { return }

        let ratio = target.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount(Double(buffer.frameLength) * ratio) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity) else { return }

        var supplied = false
        var error: NSError?
        converter.convert(to: out, error: &error) { _, status in
            if supplied {
                status.pointee = .noDataNow
                return nil
            }
            supplied = true
            status.pointee = .haveData
            return buffer
        }
        guard error == nil, out.frameLength > 0 else { return }
        do {
            try file.write(from: out)
            written += 1
        } catch {
            Log.write("회의 녹음 쓰기 실패: \(error.localizedDescription)")
        }
    }

    func close() {
        // AVAudioFile 은 놓아주면 닫힌다. 남은 것을 확실히 내보내려고 길이만 한 번 읽는다.
        _ = file.length
    }
}
