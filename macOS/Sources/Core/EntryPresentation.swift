import Foundation

package struct EntryPresentation {
    package struct OCRSnippet: Equatable {
        package let text: String
        package let highlights: [NSRange]
    }

    // 保留大文本原文，按需折叠大小写。精确和正则仍可检索任意位置。
    private static let cacheLimit = 1024 * 1024
    private(set) var preview: Preview
    let color: ClipboardColor?
    private(set) var fuzzyTokens: [FuzzyMatcher.Token]
    private(set) var cachedFields: [String]?

    init(content: Content, ocrText: String?) {
        preview = Self.render(content)
        color = ClipboardColor.parse(content)
        fuzzyTokens = FuzzyMatcher.tokens(preview: preview.text, content: content, ocrText: ocrText)
        cachedFields = Self.cache(content.searchFields(ocrText: ocrText))
    }

    private static func cache(_ fields: [String]) -> [String]? {
        guard fields.reduce(0, { $0 + $1.utf8.count }) <= cacheLimit else { return nil }
        return fields.map { $0.lowercased() }
    }

    mutating func updateOCR(_ text: String, content: Content) {
        let visible = fuzzyTokens.filter { $0.previewOffset != nil }
        fuzzyTokens = FuzzyMatcher.appendingOCR(text, to: visible)
        cachedFields = Self.cache(content.searchFields(ocrText: text))
    }

    mutating func relocalize(content: Content, ocrText: String?) {
        preview = Self.render(content)
        fuzzyTokens = FuzzyMatcher.tokens(preview: preview.text, content: content, ocrText: ocrText)
    }

    static func label(for content: Content) -> String {
        switch content { case .text: return L("文本"); case .image: return L("图片"); case .files: return L("文件") }
    }
    struct PreviewSpan {
        let source: NSRange
        let destination: Int

        func highlight(_ match: NSRange) -> NSRange? {
            let part = NSIntersectionRange(source, match)
            guard part.length > 0 else { return nil }
            return NSRange(location: destination + part.location - source.location, length: part.length)
        }
    }

    // 文件每条路径单独检索。这里只保存能对应到可见预览的原始 UTF-16 区间。
    struct Preview {
        let text: String
        let spans: [Int: [PreviewSpan]]
    }

    static func render(_ content: Content) -> Preview {
        let value: String
        let paths: [String]
        switch content {
        case let .text(text) where text.unicodeScalars.allSatisfy(CharacterSet.whitespacesAndNewlines.contains):
            return Preview(text: L("空白文本 · %ld 个字符", text.count), spans: [:])
        case let .files(files):
            paths = files
            value = files.map { ($0 as NSString).lastPathComponent }.joined(separator: L("、"))
        case let .image(width, height): return Preview(text: L("图片 · %ld × %ld 像素", width, height), spans: [:])
        case let .text(text): value = text; paths = []
        }
        let shortened: String
        let visible: [PreviewSpan]
        if value.prefix(181).count > 180 {
            let head = value.prefix(90), tail = value.suffix(90)
            shortened = String(head) + "…" + String(tail)
            visible = [PreviewSpan(source: NSRange(location: 0, length: head.utf16.count), destination: 0),
                       PreviewSpan(source: NSRange(location: value.utf16.count - tail.utf16.count, length: tail.utf16.count),
                                   destination: head.utf16.count + 1)]
        } else {
            shortened = value
            visible = [PreviewSpan(source: NSRange(location: 0, length: value.utf16.count), destination: 0)]
        }
        let text = shortened.replacingOccurrences(of: "\r", with: " ")
            .replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
        guard !paths.isEmpty else { return Preview(text: text, spans: [0: visible]) }
        var spans: [Int: [PreviewSpan]] = [:]
        var offset = 0
        let separatorLength = L("、").utf16.count
        for (field, path) in paths.enumerated() {
            let source = path as NSString
            let name = source.lastPathComponent
            let joined = NSRange(location: offset, length: name.utf16.count)
            for window in visible {
                let part = NSIntersectionRange(joined, window.source)
                guard part.length > 0 else { continue }
                let filename = source.range(of: name, options: .backwards)
                guard filename.location != NSNotFound else { continue }
                let sourceRange = NSRange(location: filename.location + part.location - offset, length: part.length)
                spans[field, default: []].append(PreviewSpan(source: sourceRange,
                    destination: window.destination + part.location - window.source.location))
            }
            offset += joined.length + separatorLength
        }
        return Preview(text: text, spans: spans)
    }

    static func detail(for content: Content) -> String {
        if case .image = content { return render(content).text }
        let value = content.searchText
        let end = value.index(value.startIndex, offsetBy: 12_000, limitedBy: value.endIndex) ?? value.endIndex
        return String(value[..<end]) + (end != value.endIndex ? "\n\n" + L("预览已截断，复制保留完整内容。") : "")
    }

    /// 为命中 OCR 文字的图片提取居中摘要与高亮区间，用于面板列表中直观展示匹配内容。
    package static func ocrSnippet(in ocrText: String, query: String) -> OCRSnippet? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.hasPrefix(">") else { return nil }

        if trimmed.hasPrefix("/") {
            return regexOCRSnippet(in: ocrText, body: trimmed.dropFirst())
        }

        let flattened = flattenOCR(ocrText)
        guard !flattened.isEmpty else { return nil }
        let request = QueryParser(trimmed)
        guard !request.terms.isEmpty else { return nil }
        var anchor: NSRange?
        for term in request.terms {
            if let range = FuzzyMatcher.exactRanges(term, in: flattened).first {
                if anchor == nil || range.location < anchor!.location { anchor = range }
            }
        }
        if anchor == nil {
            let tokens = FuzzyMatcher.previewTokens(String(flattened.prefix(4096)))
            for term in request.terms {
                if let match = FuzzyMatcher.fuzzy(term, tokens: tokens), let first = match.ranges.first {
                    if anchor == nil || first.location < anchor!.location { anchor = first }
                }
            }
        }
        guard let anchor else { return nil }
        let window = snippetWindow(in: flattened, around: anchor)
        var highlights: [NSRange] = []
        let windowTokens = FuzzyMatcher.previewTokens(window)
        for term in request.terms {
            let exact = FuzzyMatcher.exactRanges(term, in: window)
            if !exact.isEmpty {
                highlights += exact
            } else if let fuzzy = FuzzyMatcher.fuzzy(term, tokens: windowTokens) {
                highlights += fuzzy.ranges
            }
        }
        return OCRSnippet(text: window, highlights: FuzzyMatcher.merged(highlights))
    }

    private static func regexOCRSnippet(in ocrText: String, body: Substring) -> OCRSnippet? {
        guard case let .expression(expression) = QueryParser.regex(body) else { return nil }
        // 在保留换行的原文上执行正则（兼容 ^/$ 多行锚点），并限制耗时防止阻塞主线程。
        let deadline = ProcessInfo.processInfo.systemUptime + 0.025
        var firstMatch: NSRange?
        let fullRange = NSRange(ocrText.startIndex..., in: ocrText)
        expression.enumerateMatches(in: ocrText, options: .reportProgress, range: fullRange) { match, _, stop in
            if ProcessInfo.processInfo.systemUptime >= deadline {
                stop.pointee = true
                return
            }
            if let match, match.range.length > 0 {
                firstMatch = match.range
                stop.pointee = true
            }
        }
        guard let firstMatch, let swiftRange = Range(firstMatch, in: ocrText) else { return nil }
        let rawWindow = snippetWindow(in: ocrText, around: firstMatch)
        let collapsed = flattenOCR(rawWindow)
        guard !collapsed.isEmpty else { return nil }
        var ranges: [NSRange] = []
        let snippetRange = NSRange(collapsed.startIndex..., in: collapsed)
        let highlightDeadline = ProcessInfo.processInfo.systemUptime + 0.015
        expression.enumerateMatches(in: collapsed, options: .reportProgress, range: snippetRange) { match, _, stop in
            if ProcessInfo.processInfo.systemUptime >= highlightDeadline {
                stop.pointee = true
                return
            }
            if let match, match.range.length > 0 { ranges.append(match.range) }
            if ranges.count >= 32 { stop.pointee = true }
        }
        if ranges.isEmpty {
            let literal = flattenOCR(String(ocrText[swiftRange]))
            if !literal.isEmpty { ranges = FuzzyMatcher.exactRanges(literal, in: collapsed) }
        }
        return OCRSnippet(text: collapsed, highlights: FuzzyMatcher.merged(ranges))
    }

    private static func flattenOCR(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func snippetWindow(in text: String, around match: NSRange, maxLength: Int = 110) -> String {
        guard text.utf16.count > maxLength else { return text }
        let lead = min(28, maxLength / 3)
        let targetStart = max(0, match.location - lead)
        let clampedStart = min(targetStart, max(0, text.utf16.count - maxLength))
        let startUTF16 = text.utf16.index(text.utf16.startIndex, offsetBy: clampedStart)
        let startIndex: String.Index
        if let exact = startUTF16.samePosition(in: text) {
            startIndex = exact
        } else {
            // 避免把代理对或组合字符从中间截断。
            var cursor = startUTF16
            while cursor > text.utf16.startIndex && cursor.samePosition(in: text) == nil {
                text.utf16.formIndex(before: &cursor)
            }
            startIndex = cursor.samePosition(in: text) ?? text.startIndex
        }
        let startOffset = text.utf16.distance(from: text.utf16.startIndex, to: startIndex.samePosition(in: text.utf16) ?? text.utf16.startIndex)
        let endOffset = min(text.utf16.count, startOffset + maxLength)
        var endUTF16 = text.utf16.index(text.utf16.startIndex, offsetBy: endOffset)
        while endUTF16 < text.utf16.endIndex && endUTF16.samePosition(in: text) == nil {
            text.utf16.formIndex(after: &endUTF16)
        }
        let endIndex = endUTF16.samePosition(in: text) ?? text.endIndex
        let prefix = startIndex > text.startIndex ? "…" : ""
        let suffix = endIndex < text.endIndex ? "…" : ""
        return prefix + String(text[startIndex..<endIndex]).trimmingCharacters(in: .whitespaces) + suffix
    }
}
