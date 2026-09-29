import AVFoundation
import ScreenCaptureKit

/// 스피커로 나가는 소리를 잡는다. 화상회의에서 **상대방 목소리**를 들으려면 이것이 필요하다.
///
/// 마이크에는 내 목소리만 들어온다. 상대는 스피커로 나가기 때문에, 마이크만 잡는 지금 구조로는
/// 화상회의를 녹음해도 내 말만 남는다. 화자 분리를 붙여도 나눌 화자가 하나뿐이다.
///
/// 잡고 나면 덤이 있다 — 마이크=나, 시스템=상대로 **채널이 이미 갈려 있어서** 화자 분리 없이도
/// 둘이 구분된다. 상대가 여러 명일 때만 시스템 쪽에 화자 분리를 돌리면 된다.
///
/// ScreenCaptureKit 은 화면 캡처용이지만 macOS 13 부터 소리만 따로 받을 수 있다.
/// 화면은 안 쓰므로 가장 작은 크기로 두고 프레임도 거의 안 받는다.
final class SystemAudioRecorder: NSObject, SCStreamOutput, SCStreamDelegate {

    /// 소리가 들어올 때마다 부른다. 오디오 스레드에서 불리므로 무거운 일을 하면 안 된다.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?
    /// 스트림이 스스로 멈췄을 때(권한 취소, 디스플레이 변경 등). 메인 스레드 보장 없음.
    var onStop: ((Error?) -> Void)?

    private var stream: SCStream?
    private let queue = DispatchQueue(label: "com.brefly.systemaudio")

    private(set) var buffers = 0
    /// 지금까지 들어온 소리 중 가장 큰 진폭. 0 이면 무음만 받은 것이다 —
    /// 권한은 났는데 아무것도 안 들리는 상태를 이것으로 가른다.
    private(set) var peak: Float = 0

    /// 화면 기록 권한이 있는지. 없으면 `SCShareableContent` 가 오류를 던진다.
    static func hasPermission() async -> Bool {
        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            return true
        } catch {
            return false
        }
    }

    func start() async throws {
        // 소리만 쓸 거라도 필터에는 디스플레이가 있어야 한다.
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        guard let display = content.displays.first else {
            throw NSError(domain: "SystemAudio", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "디스플레이를 찾지 못했습니다"])
        }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])

        let config = SCStreamConfiguration()
        config.capturesAudio = true
        // ⚠️ 이걸 빼면 우리가 낸 소리(알림음 등)가 되돌아 들어와 섞인다.
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // 화면은 안 쓴다. 0 은 못 주므로 가장 작은 값으로 두고 프레임 간격을 크게 잡아 일을 줄인다.
        config.width = 2
        config.height = 2
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)

        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        Log.write("시스템 소리 잡기 시작 — \(display.width)×\(display.height) 디스플레이 기준")
    }

    func stop() async {
        guard let stream else { return }
        self.stream = nil
        try? await stream.stopCapture()
        Log.write("시스템 소리 잡기 멈춤 — 버퍼 \(buffers)개, 최대 진폭 \(String(format: "%.4f", peak))")
    }

    // MARK: - SCStreamOutput

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let pcm = sampleBuffer.pcmBuffer else { return }
        buffers += 1
        if let ch = pcm.floatChannelData?[0] {
            for i in 0..<Int(pcm.frameLength) { peak = max(peak, abs(ch[i])) }
        }
        onBuffer?(pcm)
    }

    // MARK: - SCStreamDelegate

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Log.write("시스템 소리 잡기 중단됨: \(error.localizedDescription)")
        onStop?(error)
    }
}

extension CMSampleBuffer {
    /// ScreenCaptureKit 은 32비트 실수 PCM 을 준다. 복사 없이 AVAudioPCMBuffer 로 감싼다.
    var pcmBuffer: AVAudioPCMBuffer? {
        try? withAudioBufferList { list, _ -> AVAudioPCMBuffer? in
            guard let asbd = formatDescription?.audioStreamBasicDescription,
                  let format = AVAudioFormat(standardFormatWithSampleRate: asbd.mSampleRate,
                                             channels: asbd.mChannelsPerFrame)
            else { return nil }
            return AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: list.unsafePointer)
        }
    }
}
