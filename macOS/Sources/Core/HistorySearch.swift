import Foundation

// 由主线程提交快照和接收结果，后台只处理最近一次查询。
@MainActor
package final class HistorySearch {
    package init() {}
    package enum Result {
        case entries([Entry], [String: [NSRange]])
        case commands(String)
        case invalidRegex
        case regexTimedOut
    }

    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.clipnest.search"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .userInitiated
        return queue
    }()
    private var pending: BlockOperation?
    package var isPending: Bool { pending != nil }

    package func cancel() {
        pending?.cancel()
        pending = nil
    }

    package func filter(_ entries: [Entry], query: String, apply: @escaping @MainActor (Result) -> Void) {
        cancel()
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix(">") { apply(.commands(String(text.dropFirst()))); return }
        if text.isEmpty { apply(.entries(entries, [:])); return }
        let operation = BlockOperation()
        pending = operation
        operation.addExecutionBlock { [weak self, weak operation] in
            guard let operation else { return }
            let result = Self.evaluate(entries, query: text, cancelled: { operation.isCancelled })
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.pending === operation else { return }
                    self.pending = nil
                    apply(result)
                }
            }
        }
        queue.addOperation(operation)
    }

    package nonisolated static func evaluate(
        _ entries: [Entry], query: String,
        matchesSourceApp: (String, String) -> Bool = AppMetadataCache.shared.matches,
        cancelled: @escaping () -> Bool = { false }
    ) -> Result {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix(">") { return .commands(String(text.dropFirst())) }
        if text.hasPrefix("/") { return RegexSearcher.evaluate(entries, body: text.dropFirst(), cancelled: cancelled) }
        return SearchRanker.evaluate(entries, request: QueryParser(text),
                                     matchesSourceApp: matchesSourceApp, cancelled: cancelled)
    }
}
