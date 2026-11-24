import Foundation

package enum FuzzyMatcher {
    struct Token {
        let text: String
        // 只有来自预览的词才可把 UTF-16 位置带回 NSTextField。
        let previewOffset: Int?
    }

    struct Match {
        let score: Int
        let ranges: [NSRange]
    }

    static func tokens(preview: String, content: Content, ocrText: String? = nil) -> [Token] {
        var result = split(preview, forPreview: true)
        var seen = Set(result.map(\.text))
        func append(_ text: String) {
            for token in split(text, forPreview: false) where seen.insert(token.text).inserted { result.append(token) }
        }
        switch content {
        case let .text(text): append(String(text.prefix(4096)))
        case let .files(paths):
            for path in paths {
                for component in path.split(separator: "/") { append(String(component)) }
            }
        case .image:
            if let ocrText { return appendingOCR(ocrText, to: result) }
        }
        return result
    }

    static func previewTokens(_ text: String) -> [Token] {
        split(text, forPreview: true)
    }

    static func appendingOCR(_ text: String, to previewTokens: [Token]) -> [Token] {
        var seen = Set(previewTokens.map(\.text))
        return previewTokens + split(String(text.prefix(4096)), forPreview: false).filter { seen.insert($0.text).inserted }
    }

    private static func split(_ text: String, forPreview: Bool) -> [Token] {
        var result: [Token] = []
        var start = text.startIndex
        var offset = 0, startOffset = 0
        func finish(_ end: String.Index) {
            // 超长连续串仍可精确检索，不为编码数据或整段压缩文本构造巨型模糊索引。
            if start < end, offset - startOffset <= 256 {
                result.append(Token(text: String(text[start..<end]), previewOffset: forPreview ? startOffset : nil))
            }
        }
        for index in text.indices {
            let character = text[index]
            let separator = !character.isLetter && !character.isNumber && !"_-.:".contains(character)
            if separator { finish(index) }
            offset += character.utf16.count
            if separator { start = text.index(after: index); startOffset = offset }
        }
        finish(text.endIndex)
        return result
    }

    package static func score(_ query: String, in text: String) -> Int? {
        let term = query.lowercased()
        if term.isEmpty { return 0 }
        if let position = exactRanges(term, in: text).first {
            return RankingWeights.aliasExact + max(0, RankingWeights.aliasPosition - position.location)
        }
        return fuzzy(term, tokens: split(text, forPreview: true))?.score
    }

    static func exactRanges(_ term: String, in text: String) -> [NSRange] {
        guard !term.isEmpty else { return [] }
        let target = text as NSString
        var ranges: [NSRange] = []
        var position = 0
        while position < target.length {
            let range = target.range(of: term, options: .caseInsensitive,
                                     range: NSRange(location: position, length: target.length - position))
            guard range.location != NSNotFound, range.length > 0 else { break }
            ranges.append(range)
            position = NSMaxRange(range)
        }
        return ranges
    }

    static func fuzzy(_ term: String, tokens: [Token]) -> Match? {
        let query = term.map { $0.lowercased() }
        guard (2...64).contains(query.count) else { return nil }
        let ascii = term.utf8.allSatisfy { $0 < 128 }
        var best: Match?
        for token in tokens {
            let letters = Array(token.text)
            guard let path = bestPath(for: query, in: letters, ascii: ascii) else { continue }
            let score = path.score + (token.previewOffset == nil ? 0 : RankingWeights.fuzzyVisible)
            if let best, score <= best.score { continue }
            var ranges: [NSRange] = []
            if var offset = token.previewOffset {
                var matches = path.positions.makeIterator()
                var next = matches.next()
                for (index, letter) in letters.enumerated() {
                    let length = letter.utf16.count
                    if index == next { ranges.append(NSRange(location: offset, length: length)); next = matches.next() }
                    offset += length
                }
            }
            best = Match(score: score, ranges: ranges)
        }
        return best
    }

    private struct Path {
        let start: Int
        let letterScore: Int
        let strongHits: Int
        let previous: Int

        func score(endingAt end: Int) -> Int {
            let span = end - start + 1
            return letterScore + max(0, RankingWeights.fuzzySpan - span)
        }

        func isPreferred(to other: Path, endingAt end: Int, ascii: Bool) -> Bool {
            // 短中文词优先保留起点靠后的路径，后续字仍有足够的跨度可用。
            if !ascii && start != other.start { return start > other.start }
            if strongHits != other.strongHits { return strongHits > other.strongHits }
            return score(endingAt: end) > other.score(endingAt: end)
        }
    }

    private static func bestPath(for query: [String], in letters: [Character], ascii: Bool) -> (positions: [Int], score: Int)? {
        guard letters.count >= query.count else { return nil }
        let folded = letters.map { $0.lowercased() }
        let boundaries = letters.indices.map { at in
            at == 0 || !(letters[at - 1].isLetter || letters[at - 1].isNumber) ||
                (letters[at].isUppercase && letters[at - 1].isLowercase)
        }
        var stages = [[Int: Path]]()
        var previous: [Int: Path] = [:]
        for (step, needle) in query.enumerated() {
            var next: [Int: Path] = [:]
            for end in step...(letters.count - query.count + step) where folded[end] == needle {
                let boundary = boundaries[end] ? 1 : 0
                if step == 0 {
                    next[end] = Path(start: end, letterScore: RankingWeights.fuzzyBoundary * boundary, strongHits: boundary, previous: -1)
                    continue
                }
                // 同一候选字母最多比较前面 16 个位置。保留前驱，最终只为获选路径生成高亮。
                for prior in max(0, end - 16)..<end {
                    guard let path = previous[prior] else { continue }
                    let span = end - path.start + 1
                    if !ascii, span > query.count * 3 { continue }
                    let adjacent = prior + 1 == end ? 1 : 0
                    let candidate = Path(start: path.start, letterScore: path.letterScore + RankingWeights.fuzzyBoundary * boundary + RankingWeights.fuzzyAdjacent * adjacent,
                                         strongHits: path.strongHits + boundary + adjacent, previous: prior)
                    if let old = next[end], !candidate.isPreferred(to: old, endingAt: end, ascii: ascii) { continue }
                    next[end] = candidate
                }
            }
            guard !next.isEmpty else { return nil }
            stages.append(next)
            previous = next
        }
        var bestEnd: Int?, bestScore = Int.min
        for end in letters.indices {
            guard let path = previous[end] else { continue }
            if ascii, query.count >= 3, path.strongHits * 3 < query.count * 2 { continue }
            let score = path.score(endingAt: end)
            if score > bestScore { bestEnd = end; bestScore = score }
        }
        guard var end = bestEnd else { return nil }
        var positions = Array(repeating: 0, count: query.count)
        for step in stages.indices.reversed() {
            positions[step] = end
            guard let path = stages[step][end] else { return nil }
            end = path.previous
        }
        return (positions, bestScore)
    }

    static func merged(_ ranges: [NSRange]) -> [NSRange] {
        var result: [NSRange] = []
        for range in ranges.filter({ $0.length > 0 }).sorted(by: { $0.location < $1.location }) {
            if let last = result.last, NSMaxRange(last) >= range.location {
                result[result.count - 1] = NSUnionRange(last, range)
            } else { result.append(range) }
        }
        return result
    }
}
