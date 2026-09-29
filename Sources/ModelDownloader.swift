import Foundation

/// 받아쓰기 모델(547MB)을 내려받는다. 회의록을 켤 때 한 번만 받는다.
///
/// 앱은 10MB, DMG 는 1.8MB 다. 모델을 번들에 넣으면 받아쓰기만 쓰는 사람도 50배 큰 파일을
/// 내려받게 된다. 그래서 회의록을 켜는 사람만 받는다.
///
/// ⚠️ 이 앱에서 **네트워크로 큰 파일을 받는 유일한 곳**이다. 실패 경우가 많으므로
///    (중간에 끊김, 디스크 부족, 잘못 받아짐) 각각을 구분해 알려 준다. "실패했습니다" 하나로
///    뭉뚱그리면 사용자가 할 수 있는 게 없다.
final class ModelDownloader: NSObject {

    struct Progress {
        let received: Int64
        let total: Int64
        var fraction: Double { total > 0 ? Double(received) / Double(total) : 0 }
        var text: String {
            let mb = { (b: Int64) in String(format: "%.0f", Double(b) / 1_048_576) }
            return total > 0 ? "\(mb(received))MB / \(mb(total))MB" : "\(mb(received))MB"
        }
    }

    enum Failure: LocalizedError {
        case network(Error)
        case badResponse(Int)
        case tooSmall(Int64)
        case cannotWrite(Error)

        var errorDescription: String? {
            switch self {
            case .network(let e):    return "내려받는 중 연결이 끊겼습니다: \(e.localizedDescription)"
            case .badResponse(let c): return "모델을 받을 수 없습니다 (서버 응답 \(c))"
            case .tooSmall(let n):   return "받은 파일이 너무 작습니다 (\(n / 1_048_576)MB). 중간에 끊긴 것 같습니다."
            case .cannotWrite(let e): return "모델을 저장하지 못했습니다: \(e.localizedDescription)"
            }
        }
    }

    /// 받아쓰기 모델. Hugging Face 가 whisper.cpp 모델의 공식 배포처다.
    private static let source = URL(string:
        "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/\(ModelStore.transcriptionModelName)")!
    /// 온전히 받았는지 보는 최소 크기. 끊긴 파일이나 오류 페이지를 걸러낸다.
    private static let leastBytes: Int64 = 400 * 1_048_576

    private var onProgress: ((Progress) -> Void)?
    private var completion: ((Result<URL, Failure>) -> Void)?
    private var session: URLSession?

    /// 이미 받아 뒀으면 아무것도 하지 않고 곧바로 끝낸다.
    func download(onProgress: @escaping (Progress) -> Void,
                  completion: @escaping (Result<URL, Failure>) -> Void) {
        if ModelStore.hasTranscriptionModel {
            completion(.success(ModelStore.transcriptionModel))
            return
        }
        self.onProgress = onProgress
        self.completion = completion
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        self.session = session
        Log.write("받아쓰기 모델 내려받기 시작 — \(ModelStore.transcriptionModelName)")
        session.downloadTask(with: Self.source).resume()
    }

    private func finish(_ result: Result<URL, Failure>) {
        session?.invalidateAndCancel()
        session = nil
        let completion = self.completion
        self.completion = nil
        self.onProgress = nil
        switch result {
        case .success(let url): Log.write("받아쓰기 모델 준비됨 — \(url.path)")
        case .failure(let error): Log.write("받아쓰기 모델 실패 — \(error.localizedDescription)")
        }
        completion?(result)
    }
}

extension ModelDownloader: URLSessionDownloadDelegate {

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        onProgress?(Progress(received: totalBytesWritten, total: totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let response = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
            finish(.failure(.badResponse(response.statusCode)))
            return
        }
        let attributes = try? FileManager.default.attributesOfItem(atPath: location.path)
        let size = (attributes?[.size] as? Int64) ?? 0
        guard size >= Self.leastBytes else {
            finish(.failure(.tooSmall(size)))
            return
        }
        do {
            // ⚠️ 옮기기 전까지는 제자리에 두지 않는다. 받다 만 파일이 제자리에 있으면
            //    다음 실행 때 "이미 있다"고 보고 깨진 모델을 쓰게 된다.
            try FileManager.default.createDirectory(at: ModelStore.directory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: ModelStore.transcriptionModel)
            try FileManager.default.moveItem(at: location, to: ModelStore.transcriptionModel)
            finish(.success(ModelStore.transcriptionModel))
        } catch {
            finish(.failure(.cannotWrite(error)))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error, completion != nil { finish(.failure(.network(error))) }
    }
}
