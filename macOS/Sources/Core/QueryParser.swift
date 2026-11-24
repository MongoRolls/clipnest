import Foundation

struct QueryParser {
    enum Filter {
        case all, text, image, files

        func matches(_ content: Content) -> Bool {
            switch (self, content) {
            case (.all, _), (.text, .text), (.image, .image), (.files, .files): return true
            default: return false
            }
        }
    }

    var filter: Filter = .all
    var apps: [String] = []
    var terms: [String] = []

    init(_ query: String) {
        for raw in query.split(whereSeparator: \.isWhitespace) {
            let token = raw.lowercased()
            switch token {
            case "type:text", "类型:文本": filter = .text
            case "type:image", "type:img", "类型:图片": filter = .image
            case "type:file", "type:files", "类型:文件": filter = .files
            default:
                if token.hasPrefix("\\"), let prefix = token.dropFirst().first, "/>#@\\".contains(prefix) {
                    terms.append(String(token.dropFirst()))
                } else if token.hasPrefix("@"), token.count > 1 { apps.append(String(token.dropFirst())) }
                else { terms.append(token) }
            }
        }
    }

    func includes(_ entry: Entry, matchesSourceApp: (String, String) -> Bool = AppMetadataCache.shared.matches) -> Bool {
        guard filter.matches(entry.content) else { return false }
        for app in apps {
            guard let source = entry.sourceAppBundleID, matchesSourceApp(app, source) else { return false }
        }
        return true
    }

    enum Regex {
        case empty, invalid
        case expression(NSRegularExpression)
    }

    static func regex(_ body: Substring) -> Regex {
        var delimiter: String.Index?, escaped = false, inClass = false
        for index in body.indices {
            let character = body[index]
            if escaped { escaped = false; continue }
            switch character {
            case "\\": escaped = true
            case "[": inClass = true
            case "]": inClass = false
            case "/" where !inClass: delimiter = index
            default: break
            }
        }
        let pattern = delimiter.map { String(body[..<$0]) } ?? String(body)
        var options: NSRegularExpression.Options = []
        if let delimiter {
            for flag in body[body.index(after: delimiter)...] {
                switch flag {
                case "i": options.insert(.caseInsensitive)
                case "m": options.insert(.anchorsMatchLines)
                case "s": options.insert(.dotMatchesLineSeparators)
                default: return .invalid
                }
            }
        }
        if pattern.isEmpty { return .empty }
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return .invalid }
        return .expression(expression)
    }
}
