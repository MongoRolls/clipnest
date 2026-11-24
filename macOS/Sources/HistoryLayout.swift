import AppKit

extension NSView {
    func pinEdges(to parent: NSView, insets: NSEdgeInsets = .init()) {
        translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            leadingAnchor.constraint(equalTo: parent.leadingAnchor, constant: insets.left),
            trailingAnchor.constraint(equalTo: parent.trailingAnchor, constant: -insets.right),
            topAnchor.constraint(equalTo: parent.topAnchor, constant: insets.top),
            bottomAnchor.constraint(equalTo: parent.bottomAnchor, constant: -insets.bottom)
        ])
    }
}

extension NSTableView {
    func select(row: Int) {
        selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
    }
}

extension DateFormatter {
    static let historyTimestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = L10n.locale
        formatter.timeZone = .autoupdatingCurrent
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()
    static func historyDate(_ date: Date) -> String {
        let locale = L10n.locale
        if historyTimestamp.locale != locale { historyTimestamp.locale = locale }
        return historyTimestamp.string(from: date)
    }
}

enum HistoryLayout {
    static let width: CGFloat = 460
    static let height: CGFloat = 620
    static let minimumHeight: CGFloat = 160
    static let controlsHeight: CGFloat = 96
    static let textRowHeight: CGFloat = 28
    static let imageRowHeight: CGFloat = 54
    static let imageHeight: CGFloat = 42
    static let rowInset: CGFloat = 10
    static let shortcutWidth: CGFloat = 30
    static let cornerRadius: CGFloat = 16
    static let screenMargin: CGFloat = 8
    static let cursorGap: CGFloat = 12
}

extension NSView {
    var usesDarkAppearance: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}

extension NSScrollView {
    static func readOnlyText(_ value: String = "", width: CGFloat = 0,
                             autohidesScrollers: Bool = false) -> (scroll: NSScrollView, textView: NSTextView) {
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: width, height: 0))
        text.isEditable = false
        text.isSelectable = true
        text.drawsBackground = false
        text.font = .systemFont(ofSize: 13)
        text.textColor = .labelColor
        text.isVerticallyResizable = true
        text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]
        text.textContainer?.widthTracksTextView = true
        if width > 0 { text.textContainer?.containerSize = NSSize(width: width, height: .greatestFiniteMagnitude) }
        text.string = value
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = autohidesScrollers
        scroll.drawsBackground = false
        scroll.documentView = text
        return (scroll, text)
    }
}
