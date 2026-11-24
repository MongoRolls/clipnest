import Foundation

enum RegexSearcher {
    static func evaluate(_ entries: [Entry], body: Substring, cancelled: @escaping () -> Bool) -> HistorySearch.Result {
        let expression: NSRegularExpression
        switch QueryParser.regex(body) {
        case .empty: return .entries(entries, [:])
        case .invalid: return .invalidRegex
        case .expression(let value): expression = value
        }
        var matches: [Entry] = [], highlights: [String: [NSRange]] = [:]
        let queryDeadline = ProcessInfo.processInfo.systemUptime + Tuning.regexQueryTimeout
        for entry in entries {
            if cancelled() { break }
            if ProcessInfo.processInfo.systemUptime >= queryDeadline { return .regexTimedOut }
            var found = false, timedOut = false
            var ranges: [NSRange] = []
            // ICU 在单条记录内也会上报进度，使病态回溯可取消。终止时丢弃部分结果。
            let deadline = min(queryDeadline, ProcessInfo.processInfo.systemUptime + Tuning.regexEntryTimeout)
            let fields = entry.content.searchFields(ocrText: entry.ocrText)
            let lastVisibleField = entry.previewSpans.keys.max() ?? -1
            for (index, field) in fields.enumerated() {
                let spans = entry.previewSpans[index] ?? []
                if found && (index > lastVisibleField || ranges.count >= 256) { break }
                if found && spans.isEmpty { continue }
                let visibleEnd = spans.last.map { NSMaxRange($0.source) } ?? 0
                expression.enumerateMatches(in: field, options: .reportProgress, range: NSRange(field.startIndex..., in: field)) { match, _, stop in
                    if cancelled() || ProcessInfo.processInfo.systemUptime >= deadline {
                        timedOut = !cancelled()
                        stop.pointee = true
                    } else if let match {
                        found = true
                        // 正则只在原文上执行，保留换行锚点、前后查找和长匹配在可见首尾的交集。
                        for span in spans {
                            if let part = span.highlight(match.range) { ranges.append(part) }
                        }
                        if NSMaxRange(match.range) >= visibleEnd || ranges.count >= 256 { stop.pointee = true }
                    }
                }
                if ProcessInfo.processInfo.systemUptime >= deadline, !cancelled() { timedOut = true }
                if timedOut || cancelled() { break }
            }
            if timedOut { return .regexTimedOut }
            if found {
                matches.append(entry)
                if !ranges.isEmpty { highlights[entry.id] = FuzzyMatcher.merged(ranges) }
            }
        }
        return .entries(matches, highlights)
    }
}
