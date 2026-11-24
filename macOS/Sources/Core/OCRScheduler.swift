import Foundation

// 这里只处理记录 ID 和事件。图片解码、数据库写入及用户回调由外层执行。
package struct OCRScheduler {
    package struct Job: Equatable {
        package let id: String
        package let manual: Bool
        fileprivate let number: Int
    }
    package enum Event {
        case candidates([String]), automatic(Bool), manual(String)
        case finished(Job, failed: Bool)
        case sleep, wake, stop
    }
    package enum Action: Equatable {
        case start(Job), cancelActive, deliver(String), cancelWaiting
    }
    private var candidates: [String] = []
    private var manualIDs: [String] = []
    private var failures = Set<String>()
    private var active: Job?
    private var cancelling = false
    private var automatic = true
    private var sleeping = false
    private var stopped = false
    private var number = 0

    package init() {}
    package mutating func receive(_ event: Event) -> [Action] {
        var actions: [Action] = []
        switch event {
        case .candidates(let ids): candidates = ids
        case .automatic(let enabled): automatic = enabled
        case .manual(let id):
            guard !stopped, !sleeping else { return [.cancelWaiting] }
            if !manualIDs.contains(id) { manualIDs.append(id) }
        case let .finished(job, failed):
            guard active == job else { return [] }
            if !cancelling {
                if failed { failures.insert(job.id) } else { failures.remove(job.id) }
                candidates.removeAll { $0 == job.id }
                manualIDs.removeAll { $0 == job.id }
                actions.append(.deliver(job.id))
            }
            active = nil
            cancelling = false
        case .sleep, .stop:
            if case .stop = event { stopped = true } else { sleeping = true }
            manualIDs.removeAll()
            actions.append(.cancelWaiting)
        case .wake: sleeping = false
        }
        if let active {
            // 同图手动请求接入正在运行的后台任务。另一张图可以抢先，取消后仍保留原候选。
            let preempt = !manualIDs.contains(active.id) && (!automatic || !manualIDs.isEmpty)
            if !cancelling && (stopped || sleeping || preempt) {
                cancelling = true
                actions.insert(.cancelActive, at: 0)
            }
        } else if !stopped && !sleeping {
            let candidate = manualIDs.first ?? (automatic ? candidates.first { !failures.contains($0) } : nil)
            if let candidate {
                number += 1
                let job = Job(id: candidate, manual: manualIDs.first == candidate, number: number)
                active = job
                // 用户回调可能同步发起下一次操作，先为新任务安装取消令牌。
                actions.insert(.start(job), at: 0)
            }
        }
        return actions
    }
}
