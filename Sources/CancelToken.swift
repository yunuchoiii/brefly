import Foundation

/// 오래 걸리는 일을 중간에 멈추기 위한 표. 여러 스레드에서 읽고 쓴다.
///
/// 회의록은 1~2분이 걸린다. 잘못된 파일을 고르고 끝날 때까지 기다리게 두면 안 된다.
final class CancelToken {
    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }
}
