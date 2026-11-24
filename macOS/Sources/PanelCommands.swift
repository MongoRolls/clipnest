import AppKit

enum PanelCommand: String, CaseIterable {
    case pause, clear, settings, favorites, history
    case system = "appearance system", dark = "appearance dark", light = "appearance light"
    case paste, plainText = "plain", imageOCR = "ocr", quit

    func title(paused: Bool, directPaste: Bool, plainText: Bool = false, imageOCR: Bool = true) -> String {
        switch self {
        case .pause: return paused ? L("恢复记录") : L("暂停记录")
        case .clear: return L("清空历史…")
        case .settings: return L("打开设置…")
        case .favorites: return L("查看收藏")
        case .history: return L("返回历史")
        case .system: return L("面板外观 · 跟随系统")
        case .dark: return L("面板外观 · 深色")
        case .light: return L("面板外观 · 浅色")
        case .paste: return directPaste ? L("关闭直接粘贴") : L("开启直接粘贴")
        case .plainText: return plainText ? L("关闭默认纯文本") : L("开启默认纯文本")
        case .imageOCR: return imageOCR ? L("关闭图片文字搜索") : L("开启图片文字搜索")
        case .quit: return L("退出 ClipNest")
        }
    }

    private var aliases: String {
        switch self {
        case .pause: return "暂停记录 恢复记录 pause resume capture recording"
        case .clear: return "清空历史 clear history"
        case .settings: return "打开设置 preferences settings"
        case .favorites: return "查看收藏 saved favorites"
        case .history: return "返回历史 show history"
        case .system: return "面板外观 跟随系统 appearance system"
        case .dark: return "面板外观 深色 appearance dark"
        case .light: return "面板外观 浅色 appearance light"
        case .paste: return "开启直接粘贴 关闭直接粘贴 enable disable direct paste"
        case .plainText: return "开启默认纯文本 关闭默认纯文本 默认纯文本 复制纯文本 plain text format rich"
        case .imageOCR: return "开启图片文字搜索 关闭图片文字搜索 自动识别图片文字 图片搜索 ocr image text search"
        case .quit: return "退出 ClipNest quit exit"
        }
    }

    static func matching(_ query: String, paused: Bool, directPaste: Bool, plainText: Bool = false, imageOCR: Bool = true) -> [PanelCommand] {
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !terms.isEmpty else { return allCases }
        var matches = [(command: PanelCommand, score: Int, order: Int)]()
        for (index, command) in allCases.enumerated() {
            let text = [command.rawValue, command.title(paused: paused, directPaste: directPaste, plainText: plainText, imageOCR: imageOCR), command.aliases].joined(separator: " ")
            let scores = terms.compactMap { FuzzyMatcher.score($0, in: text) }
            if scores.count == terms.count {
                let exact = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == command.rawValue
                matches.append((command, scores.reduce(0, +) + (exact ? 2000 : 0), index))
            }
        }
        return matches.sorted { $0.score == $1.score ? $0.order < $1.order : $0.score > $1.score }.map(\.command)
    }
}

final class PanelCommandCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("panel-command")
    private let title = NSTextField(labelWithString: "")
    private let alias = NSTextField(labelWithString: "")
    private let shortcut = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.reuseIdentifier
        title.font = .systemFont(ofSize: 14)
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        alias.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        shortcut.font = .systemFont(ofSize: 13, weight: .medium)
        shortcut.alignment = .right
        for field in [title, alias, shortcut] {
            field.translatesAutoresizingMaskIntoConstraints = false
            addSubview(field)
            field.centerYAnchor.constraint(equalTo: centerYAnchor).isActive = true
        }
        NSLayoutConstraint.activate([
            title.leadingAnchor.constraint(equalTo: leadingAnchor, constant: HistoryLayout.rowInset),
            title.trailingAnchor.constraint(equalTo: alias.leadingAnchor, constant: -8),
            alias.trailingAnchor.constraint(equalTo: shortcut.leadingAnchor, constant: -8),
            shortcut.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -HistoryLayout.rowInset),
            shortcut.widthAnchor.constraint(equalToConstant: HistoryLayout.shortcutWidth)
        ])
    }

    required init?(coder: NSCoder) { fatalError("不支持从归档创建命令行。") }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { updateColors() }
    }

    private func updateColors() {
        let selected = backgroundStyle == .emphasized
        title.textColor = selected ? .white : .labelColor
        alias.textColor = selected ? .white : .secondaryLabelColor
        shortcut.textColor = alias.textColor
    }

    func configure(command: PanelCommand, title: String, shortcut: String) {
        self.title.stringValue = title
        alias.stringValue = ">\(command.rawValue)"
        self.shortcut.stringValue = shortcut
        updateColors()
        setAccessibilityLabel("\(title) · \(alias.stringValue)")
    }
}
