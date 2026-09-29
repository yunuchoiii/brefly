import Foundation

/// 받아쓰기 모델이 사는 곳. 앱 번들에 넣을 수 없어서(547MB) 회의록을 켤 때 따로 받는다.
///
/// 앱은 6.3MB, DMG 는 1.8MB 다. 모델을 번들에 넣으면 받는 사람이 100배 큰 파일을 내려받게 되고,
/// 받아쓰기만 쓰는 사람에게는 쓸모없는 용량이다. 그래서 회의록 기능을 켤 때만 받는다.
enum ModelStore {

    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Brefly/models", isDirectory: true)
    }

    /// 양자화된 large-v3-turbo. 547MB 로 큰 편이지만, 35분 녹음을 124초에 받아쓴다(2026-09-29 실측).
    /// 양자화 안 한 것은 1.5GB 인데 이만큼 빠르지 않다.
    static let transcriptionModelName = "ggml-large-v3-turbo-q5_0.bin"

    static var transcriptionModel: URL {
        directory.appendingPathComponent(transcriptionModelName)
    }

    static var hasTranscriptionModel: Bool {
        FileManager.default.fileExists(atPath: transcriptionModel.path)
    }
}
