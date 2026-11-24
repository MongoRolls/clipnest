import Foundation

enum RankingWeights {
    // 先按是否全部精确命中分组，再比较可见预览、词边界及命中位置，最后保留原始顺序。
    static let visibleExact = 300
    static let visiblePosition = 180
    static let visibleBoundary = 80
    static let bodyExact = 100
    static let bodyPosition = 64
    static let bodyBoundary = 30
    static let positionStride = 16
    // 别名匹配中精确包含优先。模糊路径奖励可见词、连续字母、单词边界和较短跨度。
    static let aliasExact = 1000
    static let aliasPosition = 100
    static let fuzzyVisible = 40
    static let fuzzySpan = 32
    static let fuzzyBoundary = 10
    static let fuzzyAdjacent = 8
}

enum SearchRanker {
    private struct Hit {
        let entry: Entry
        let allExact: Bool
        let score: Int
        let order: Int
        let ranges: [NSRange]
    }

    static func evaluate(_ entries: [Entry], request: QueryParser,
                         matchesSourceApp: (String, String) -> Bool = AppMetadataCache.shared.matches,
                         cancelled: () -> Bool) -> HistorySearch.Result {
        var hits: [Hit] = []
        for (order, entry) in entries.enumerated() {
            if cancelled() { break }
            guard request.includes(entry, matchesSourceApp: matchesSourceApp) else { continue }
            if let hit = match(request.terms, entry: entry, order: order, cancelled: cancelled) { hits.append(hit) }
        }
        if !request.terms.isEmpty {
            hits.sort {
                if $0.allExact != $1.allExact { return $0.allExact }
                if $0.score != $1.score { return $0.score > $1.score }
                return $0.order < $1.order
            }
        }
        var highlights: [String: [NSRange]] = [:]
        for hit in hits where !hit.ranges.isEmpty { highlights[hit.entry.id] = hit.ranges }
        return .entries(hits.map(\.entry), highlights)
    }

    private static func match(_ terms: [String], entry: Entry, order: Int, cancelled: () -> Bool) -> Hit? {
        var exact = true, score = 0
        var ranges: [NSRange] = []
        let positions = exactScores(for: terms, in: entry, cancelled: cancelled)
        for (term, position) in zip(terms, positions) {
            if cancelled() { return nil }
            if let position {
                let visible = FuzzyMatcher.exactRanges(term, in: entry.preview)
                if let first = visible.first {
                    let start = first.location
                    let label = entry.preview as NSString
                    let atBoundary = start == 0 || !(CharacterSet.alphanumerics as NSCharacterSet).characterIsMember(label.character(at: start - 1))
                    score += RankingWeights.visibleExact + max(0, RankingWeights.visiblePosition - start) + (atBoundary ? RankingWeights.visibleBoundary : 0)
                    ranges += visible
                }
                score += RankingWeights.bodyExact + position
            } else if let match = FuzzyMatcher.fuzzy(term, tokens: entry.fuzzyTokens) {
                exact = false
                score += match.score
                ranges += match.ranges
            } else { return nil }
        }
        // 图片行绘制缩略图。尺寸或 OCR 恰好命中图片说明时也没有可高亮的文字。
        if case .image = entry.content { ranges.removeAll() }
        return Hit(entry: entry, allExact: exact, score: score, order: order, ranges: FuzzyMatcher.merged(ranges))
    }

    static func exactScores(for terms: [String], in entry: Entry, cancelled: () -> Bool) -> [Int?] {
        var scores = Array<Int?>(repeating: nil, count: terms.count)
        var remaining = terms.count
        func scan(_ field: String, base: Int) {
            for index in terms.indices where scores[index] == nil {
                guard let start = field.range(of: terms[index])?.lowerBound else { continue }
                let previous = start == field.startIndex ? nil : field[field.index(before: start)]
                let boundary = previous.map { !$0.isLetter && !$0.isNumber } ?? true
                let offset = base + start.utf16Offset(in: field)
                scores[index] = max(0, RankingWeights.bodyPosition - offset / RankingWeights.positionStride)
                    + (boundary ? RankingWeights.bodyBoundary : 0)
                remaining -= 1
            }
        }
        if let fields = entry.cachedSearchIndex {
            for field in fields where remaining > 0 { scan(field, base: 0) }
            return scores
        }
        for text in entry.content.searchFields(ocrText: entry.ocrText) where remaining > 0 {
            var start = text.startIndex, base = 0
            let bytes = text.utf8
            while start < text.endIndex && remaining > 0 && !cancelled() {
                // 普通查询词没有换行。完整换行也隔开 Unicode 大小写上下文，逐段处理仍能取得相同的首命中。
                let cut = bytes.index(start, offsetBy: 64 * 1024, limitedBy: bytes.endIndex) ?? bytes.endIndex
                let end = bytes[cut...].firstIndex(of: 10).map { bytes.index(after: $0) } ?? text.endIndex
                let folded = text[start..<end].lowercased()
                scan(folded, base: base)
                base += folded.utf16.count
                start = end
            }
        }
        return scores
    }
}
