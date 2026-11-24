import AppKit

final class FooterButton: NSButton {
    private let shortcut: String
    private var hoverArea: NSTrackingArea?
    private var pointerInside = false {
        didSet { if pointerInside != oldValue { needsDisplay = true } }
    }

    init(title: String, shortcut: String = "", target: AnyObject, action: Selector) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        self.title = title
        self.target = target
        self.action = action
        isBordered = false
        font = .systemFont(ofSize: 13)
        setContentHuggingPriority(.required, for: .horizontal)
        heightAnchor.constraint(equalToConstant: 26).isActive = true
        if !shortcut.isEmpty { setAccessibilityHelp(L("快捷键 %@", shortcut)) }
    }

    required init?(coder: NSCoder) { fatalError("不支持从归档创建底部按钮。") }

    override var title: String {
        didSet {
            guard title != oldValue else { return }
            toolTip = shortcut.isEmpty ? title : "\(title) (\(shortcut))"
            invalidateIntrinsicContentSize()
            needsDisplay = true
        }
    }

    private var titleFont: NSFont { font ?? .systemFont(ofSize: 13) }
    override var intrinsicContentSize: NSSize {
        let width = (title as NSString).size(withAttributes: [.font: titleFont]).width
        return NSSize(width: ceil(width) + 16, height: 26)
    }

    override var isEnabled: Bool {
        didSet {
            if isEnabled != oldValue { window?.invalidateCursorRects(for: self) }
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()
        if isEnabled { addCursorRect(bounds.intersection(visibleRect), cursor: .pointingHand) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
            owner: self, userInfo: nil)
        addTrackingArea(area)
        hoverArea = area
        pointerInside = window.map { $0.isKeyWindow && bounds.contains(convert($0.mouseLocationOutsideOfEventStream, from: nil)) } ?? false
    }
    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        if event.trackingArea === hoverArea { pointerInside = bounds.contains(convert(event.locationInWindow, from: nil)) }
    }
    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        if event.trackingArea === hoverArea { pointerInside = false }
    }

    override func draw(_ dirtyRect: NSRect) {
        let highlighted = isEnabled && (pointerInside || isHighlighted)
        if highlighted {
            let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 0.5), xRadius: 6, yRadius: 6)
            let fill = usesDarkAppearance
                ? NSColor.white.withAlphaComponent(isHighlighted ? 0.18 : 0.11)
                : NSColor.black.withAlphaComponent(isHighlighted ? 0.14 : 0.07)
            fill.setFill()
            shape.fill()
            NSColor.separatorColor.setStroke()
            shape.lineWidth = 1 / (window?.backingScaleFactor ?? 1)
            shape.stroke()
        }
        let titleColor: NSColor = isEnabled ? .labelColor : .disabledControlTextColor
        let text = NSAttributedString(string: title, attributes: [.font: titleFont, .foregroundColor: titleColor])
        let size = text.size()
        text.draw(at: NSPoint(x: bounds.midX - size.width / 2, y: bounds.midY - size.height / 2))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
