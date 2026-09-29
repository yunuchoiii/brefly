import AVFoundation
import Speech

/// 진단용: 소리 파일을 받아쓰기만 해 본다. 녹음 없이 인식기만 재려고 만들었다.
///
/// 회의록 기능을 검토하면서 애플 인식이 긴 소리를 어디까지 받아쓰는지, 화자 분리에 필요한
/// 시간 정보가 실제로 나오는지 재야 했다. 명령줄 도구를 따로 만들면 TCC 가 프로세스를 죽인다
/// — Info.plist 의 `NSSpeechRecognitionUsageDescription` 이 없기 때문이다. 그래서 앱 안에 둔다.
enum Transcriber {

    struct Report {
        let seconds: Double
        let text: String
        /// 인식기가 돌려준 낱말 구간. 화자 분리는 이 시간 정보와 화자 구간을 겹쳐 맞춰야 한다.
        let segments: Int
        /// 그중 시각이 0 이 아닌 것. 전부 0 이면 겹쳐 맞출 방법이 없다.
        let timed: Int
        let lastTimestamp: Double
    }

    /// 파일의 한 구간만 잘라 임시 파일로 뽑는다. 애플 인식기는 파일 전체를 받으므로 자를 수밖에 없다.
    private static func slice(_ src: URL, from: Double, seconds: Double) -> URL? {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("brefly-slice-\(Int(from))-\(Int(seconds)).m4a")
        try? FileManager.default.removeItem(at: out)
        guard let export = AVAssetExportSession(asset: AVURLAsset(url: src),
                                                presetName: AVAssetExportPresetAppleM4A) else { return nil }
        export.outputURL = out
        export.outputFileType = .m4a
        export.timeRange = CMTimeRange(start: CMTime(seconds: from, preferredTimescale: 600),
                                       duration: CMTime(seconds: seconds, preferredTimescale: 600))
        let done = DispatchSemaphore(value: 0)
        export.exportAsynchronously { done.signal() }
        _ = done.wait(timeout: .now() + 120)
        return export.status == .completed ? out : nil
    }

    /// - Parameters:
    ///   - from: 파일에서 이 초부터. 0 이면 처음부터.
    ///   - seconds: 이만큼만. 0 이면 파일 전체.
    ///   - onDevice: 앱 기본값은 애플 서버다(`forceServerRecognition`). 온디바이스와 견주려면 켠다.
    static func run(_ path: String, from: Double, seconds: Double, onDevice: Bool,
                    completion: @escaping (Result<Report, Error>) -> Void) {
        let src = URL(fileURLWithPath: path)
        let target: URL
        if seconds > 0 {
            guard let cut = slice(src, from: from, seconds: seconds) else {
                completion(.failure(NSError(domain: "Transcriber", code: 1,
                                            userInfo: [NSLocalizedDescriptionKey: "소리를 자르지 못했습니다"])))
                return
            }
            target = cut
        } else {
            target = src
        }

        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: "ko-KR")) else {
            completion(.failure(NSError(domain: "Transcriber", code: 2,
                                        userInfo: [NSLocalizedDescriptionKey: "한국어 인식기를 만들지 못했습니다"])))
            return
        }
        // ⚠️ 인식기는 결과를 기본적으로 **메인 큐**로 보낸다. 진단 플래그는 메인 스레드를 세마포어로
        // 막고 기다리므로, 이걸 안 바꾸면 결과가 영영 안 온다(60초 소리로 400초를 기다렸다).
        recognizer.queue = OperationQueue()

        let request = SFSpeechURLRecognitionRequest(url: target)
        request.requiresOnDeviceRecognition = onDevice
        request.shouldReportPartialResults = false
        request.addsPunctuation = true

        let started = Date()
        recognizer.recognitionTask(with: request) { result, error in
            if let error {
                completion(.failure(error))
                return
            }
            guard let result, result.isFinal else { return }
            let segments = result.bestTranscription.segments
            completion(.success(Report(
                seconds: Date().timeIntervalSince(started),
                text: result.bestTranscription.formattedString,
                segments: segments.count,
                timed: segments.filter { $0.timestamp > 0 }.count,
                lastTimestamp: segments.last?.timestamp ?? 0
            )))
        }
    }
}
