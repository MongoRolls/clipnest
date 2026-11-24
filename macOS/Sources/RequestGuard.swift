import Foundation

/// 同一用途的下一次请求或取消操作都会使旧票据失效；不同用途各自持有实例。
struct RequestGuard {
    private(set) var ticket = UUID()
    private(set) var isPending = false

    @discardableResult mutating func begin() -> UUID {
        ticket = UUID()
        isPending = true
        return ticket
    }

    mutating func invalidate() {
        ticket = UUID()
        isPending = false
    }

    func isCurrent(_ value: UUID) -> Bool { ticket == value }
}
