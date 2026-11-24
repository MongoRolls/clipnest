import Foundation

// 取消状态与回调的登记均由同一把锁保护，调用回调前释放锁。
final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var handler: (() -> Void)?
    var isCancelled: Bool { lock.withLock { cancelled } }

    func cancel() {
        let notify: (() -> Void)? = lock.withLock {
            guard !cancelled else { return nil }
            cancelled = true
            defer { handler = nil }
            return handler
        }
        notify?()
    }

    func setHandler(_ value: (() -> Void)?) {
        let alreadyCancelled = lock.withLock {
            if !cancelled { handler = value }
            return cancelled
        }
        if alreadyCancelled { value?() }
    }
}
