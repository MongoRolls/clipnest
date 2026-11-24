import AppKit

/// 自顶向下排布的容器，供设置页滚动视图使用。
final class SettingsFlippedView: NSView {
    override var isFlipped: Bool { true }
}

/// 允许拖动窗口的顶部空白或标题栏区域。
final class SettingsDragArea: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

/// 卡片内行间细分隔线，随系统浅深外观自适应。
final class SettingsHairlineView: NSView {
    private let horizontalInset: CGFloat

    init(horizontalInset: CGFloat = 14) {
        self.horizontalInset = horizontalInset
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 1).isActive = true
    }

    required init?(coder: NSCoder) { fatalError("不支持从归档创建分隔线。") }

    override func draw(_ dirtyRect: NSRect) {
        let pixel = 1 / (window?.backingScaleFactor ?? 1)
        let width = bounds.width - horizontalInset * 2
        guard width > 0 else { return }
        let color = usesDarkAppearance
            ? NSColor.white.withAlphaComponent(0.09)
            : NSColor.black.withAlphaComponent(0.07)
        color.setFill()
        NSRect(x: horizontalInset, y: floor((bounds.height - pixel) / 2), width: width, height: pixel).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// 系统设置风格的圆角分组卡片，自动维护可见行之间的分隔线。
final class SettingsCardView: NSView {
    private struct Entry {
        let view: NSView
        let dividerAbove: SettingsHairlineView?
    }

    private let stack = NSStackView()
    private var entries: [Entry] = []

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        addSubview(stack)
        stack.pinEdges(to: self)
    }

    required init?(coder: NSCoder) { fatalError("不支持从归档创建设置卡片。") }

    @discardableResult
    func addRow(_ row: NSView) -> NSView {
        let divider: SettingsHairlineView? = entries.isEmpty ? nil : SettingsHairlineView()
        if let divider {
            stack.addArrangedSubview(divider)
            divider.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        row.translatesAutoresizingMaskIntoConstraints = false
        stack.addArrangedSubview(row)
        row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        entries.append(Entry(view: row, dividerAbove: divider))
        updateDividers()
        return row
    }

    func clearRows() {
        for view in stack.arrangedSubviews {
            stack.removeArrangedSubview(view)
            view.removeFromSuperview()
        }
        entries.removeAll()
    }

    func updateDividers() {
        var sawVisible = false
        for entry in entries {
            let visible = !entry.view.isHidden
            entry.dividerAbove?.isHidden = !(visible && sawVisible)
            if visible { sawVisible = true }
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        let pixel = 1 / (window?.backingScaleFactor ?? 1)
        let rect = bounds.insetBy(dx: pixel / 2, dy: pixel / 2)
        guard !rect.isEmpty else { return }
        let path = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        let fill = usesDarkAppearance
            ? NSColor.white.withAlphaComponent(0.055)
            : NSColor.black.withAlphaComponent(0.030)
        let stroke = usesDarkAppearance
            ? NSColor.white.withAlphaComponent(0.095)
            : NSColor.black.withAlphaComponent(0.075)
        fill.setFill()
        path.fill()
        stroke.setStroke()
        path.lineWidth = pixel
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// 带柔和强调色底纹的圆角符号图标，用于重点功能行。
final class SettingsIconBadgeView: NSView {
    private let icon = NSImageView()

    init(symbol: String, tint: NSColor = .controlAccentColor) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 14, weight: .medium)
        icon.contentTintColor = tint
        icon.setAccessibilityElement(false)
        addSubview(icon)
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 28),
            heightAnchor.constraint(equalToConstant: 28),
            icon.centerXAnchor.constraint(equalTo: centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("不支持从归档创建图标徽章。") }

    override func draw(_ dirtyRect: NSRect) {
        let color = NSColor.controlAccentColor.withAlphaComponent(usesDarkAppearance ? 0.22 : 0.12)
        color.setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 7, yRadius: 7).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// 标题旁的轻底纹胶囊状态徽章，用于展示权限或开关状态。
final class SettingsStatusBadgeView: NSView {
    private let dot = NSImageView()
    private let value = NSTextField(labelWithString: "")
    private var tintColor: NSColor = .secondaryLabelColor

    init(label: String) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        dot.translatesAutoresizingMaskIntoConstraints = false
        dot.image = NSImage(systemSymbolName: "circle.fill", accessibilityDescription: nil)
        dot.symbolConfiguration = .init(pointSize: 6.5, weight: .regular)
        dot.setAccessibilityElement(false)
        value.translatesAutoresizingMaskIntoConstraints = false
        value.font = .systemFont(ofSize: 11, weight: .medium)
        value.setAccessibilityLabel(label)
        addSubview(dot)
        addSubview(value)
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        NSLayoutConstraint.activate([
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            value.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 4.5),
            value.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            value.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            value.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        ])
        updateColors()
    }

    required init?(coder: NSCoder) { fatalError("不支持从归档创建权限状态。") }

    func show(_ text: String, _ color: NSColor) {
        tintColor = color
        value.stringValue = text
        updateColors()
        needsDisplay = true
    }

    private func updateColors() {
        dot.contentTintColor = tintColor
        value.textColor = NSColor.labelColor.withAlphaComponent(usesDarkAppearance ? 0.86 : 0.72)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard !bounds.isEmpty else { return }
        let radius = bounds.height / 2
        tintColor.withAlphaComponent(usesDarkAppearance ? 0.16 : 0.11).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
        needsDisplay = true
    }
}

/// 设置卡片中的单行布局：左侧可选图标 + 标题（含可选状态胶囊）与副标题，右侧紧贴排布的交互控件。
final class SettingsRowView: NSView {
    let titleLabel: NSTextField
    let subtitleLabel: NSTextField

    init(icon: String? = nil, title: String, titleBadge: NSView? = nil,
         subtitle: String? = nil, trailing: [NSView] = []) {
        titleLabel = NSTextField(wrappingLabelWithString: title)
        subtitleLabel = NSTextField(wrappingLabelWithString: subtitle ?? "")
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false

        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.textColor = .labelColor
        titleLabel.isSelectable = false
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        subtitleLabel.font = .systemFont(ofSize: 11.5)
        subtitleLabel.textColor = .secondaryLabelColor
        subtitleLabel.isSelectable = false
        subtitleLabel.isHidden = subtitle?.isEmpty ?? true
        subtitleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let textStack = NSStackView()
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 3
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.setHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(textStack)

        var constraints: [NSLayoutConstraint] = [
            heightAnchor.constraint(greaterThanOrEqualToConstant: 44),
            textStack.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 10),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -10),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ]

        if let titleBadge {
            titleLabel.setContentHuggingPriority(.required, for: .horizontal)
            titleBadge.setContentHuggingPriority(.required, for: .horizontal)
            titleBadge.setContentCompressionResistancePriority(.required, for: .horizontal)
            let titleRow = NSStackView(views: [titleLabel, titleBadge])
            titleRow.orientation = .horizontal
            titleRow.alignment = .centerY
            titleRow.spacing = 8
            titleRow.setHuggingPriority(.required, for: .horizontal)
            textStack.addArrangedSubview(titleRow)
            constraints.append(titleRow.trailingAnchor.constraint(lessThanOrEqualTo: textStack.trailingAnchor))
        } else {
            titleLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
            textStack.addArrangedSubview(titleLabel)
            constraints.append(titleLabel.widthAnchor.constraint(equalTo: textStack.widthAnchor))
        }
        textStack.addArrangedSubview(subtitleLabel)
        constraints.append(subtitleLabel.widthAnchor.constraint(equalTo: textStack.widthAnchor))

        if let icon {
            let badge = SettingsIconBadgeView(symbol: icon)
            addSubview(badge)
            constraints += [
                badge.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
                badge.centerYAnchor.constraint(equalTo: centerYAnchor),
                textStack.leadingAnchor.constraint(equalTo: badge.trailingAnchor, constant: 12)
            ]
        } else {
            constraints.append(textStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14))
        }

        if !trailing.isEmpty {
            let accessory = NSStackView(views: trailing)
            accessory.orientation = .horizontal
            accessory.alignment = .centerY
            accessory.spacing = 8
            accessory.translatesAutoresizingMaskIntoConstraints = false
            // NSStackView 默认水平 hugging 较低，必须显式设为 required 以防多个控件间被拉散。
            accessory.setHuggingPriority(.required, for: .horizontal)
            accessory.setHuggingPriority(.required, for: .vertical)
            accessory.setContentHuggingPriority(.required, for: .horizontal)
            accessory.setContentCompressionResistancePriority(.required, for: .horizontal)
            for control in trailing {
                (control as? NSStackView)?.setHuggingPriority(.required, for: .horizontal)
                control.setContentHuggingPriority(.required, for: .horizontal)
                control.setContentCompressionResistancePriority(.required, for: .horizontal)
            }
            addSubview(accessory)
            constraints += [
                accessory.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
                accessory.centerYAnchor.constraint(equalTo: centerYAnchor),
                accessory.topAnchor.constraint(greaterThanOrEqualTo: topAnchor, constant: 8),
                accessory.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -8),
                textStack.trailingAnchor.constraint(equalTo: accessory.leadingAnchor, constant: -14)
            ]
        } else {
            constraints.append(textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14))
        }
        NSLayoutConstraint.activate(constraints)
    }

    required init?(coder: NSCoder) { fatalError("不支持从归档创建设置行。") }

    func setSubtitle(_ text: String?, color: NSColor = .secondaryLabelColor) {
        subtitleLabel.stringValue = text ?? ""
        subtitleLabel.textColor = color
        subtitleLabel.isHidden = text?.isEmpty ?? true
    }
}

/// 展示按键组合或搜索前缀的胶囊标签。
final class SettingsKeycapView: NSView {
    private let label: NSTextField

    init(_ text: String, monospaced: Bool = false) {
        label = NSTextField(labelWithString: text)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = monospaced
            ? .monospacedSystemFont(ofSize: 11.5, weight: .medium)
            : .systemFont(ofSize: 11.5, weight: .medium)
        label.textColor = .secondaryLabelColor
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 3),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -3)
        ])
    }

    required init?(coder: NSCoder) { fatalError("不支持从归档创建按键标签。") }

    override func draw(_ dirtyRect: NSRect) {
        let pixel = 1 / (window?.backingScaleFactor ?? 1)
        let rect = bounds.insetBy(dx: pixel / 2, dy: pixel / 2)
        guard !rect.isEmpty else { return }
        let path = NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)
        let fill = usesDarkAppearance
            ? NSColor.white.withAlphaComponent(0.08)
            : NSColor.black.withAlphaComponent(0.045)
        let stroke = usesDarkAppearance
            ? NSColor.white.withAlphaComponent(0.12)
            : NSColor.black.withAlphaComponent(0.08)
        fill.setFill()
        path.fill()
        stroke.setStroke()
        path.lineWidth = pixel
        path.stroke()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// 单个可滚动设置详情页，承载多个分组卡片与说明文字。
final class SettingsPage: NSViewController {
    private let scroll = NSScrollView()
    private let document = SettingsFlippedView()
    private let sections = NSStackView()

    var contentHeight: CGFloat { ceil(sections.fittingSize.height) + 40 }

    init() {
        super.init(nibName: nil, bundle: nil)
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        scroll.horizontalScrollElasticity = .none

        document.translatesAutoresizingMaskIntoConstraints = false
        sections.orientation = .vertical
        sections.alignment = .leading
        sections.spacing = 20
        sections.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(sections)
        scroll.documentView = document

        NSLayoutConstraint.activate([
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            sections.topAnchor.constraint(equalTo: document.topAnchor, constant: 18),
            sections.leadingAnchor.constraint(equalTo: document.leadingAnchor, constant: 24),
            sections.trailingAnchor.constraint(equalTo: document.trailingAnchor, constant: -24),
            sections.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -24)
        ])
        view = scroll
    }

    required init?(coder: NSCoder) { fatalError("不支持从归档创建设置页。") }

    @discardableResult
    func addSection(title: String? = nil, footer: String? = nil,
                    configure: (SettingsCardView) -> Void) -> (card: SettingsCardView, footer: NSTextField?) {
        let card = SettingsCardView()
        configure(card)
        return (card, addSection(title: title, content: card, footer: footer))
    }

    @discardableResult
    func addSection(title: String? = nil, content: NSView, footer: String? = nil) -> NSTextField? {
        let group = NSStackView()
        group.orientation = .vertical
        group.alignment = .leading
        group.spacing = 6
        group.translatesAutoresizingMaskIntoConstraints = false

        if let title, !title.isEmpty {
            let header = NSTextField(labelWithString: title)
            header.font = .systemFont(ofSize: 13, weight: .semibold)
            header.textColor = .labelColor
            let inset = NSStackView(views: [header])
            inset.edgeInsets = NSEdgeInsets(top: 0, left: 2, bottom: 2, right: 0)
            group.addArrangedSubview(inset)
        }

        content.translatesAutoresizingMaskIntoConstraints = false
        group.addArrangedSubview(content)
        content.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true

        var footerField: NSTextField?
        if let footer {
            let field = NSTextField(wrappingLabelWithString: footer)
            field.font = .systemFont(ofSize: 11.5)
            field.textColor = .secondaryLabelColor
            field.isSelectable = false
            field.isHidden = footer.isEmpty
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            let wrapper = NSView()
            wrapper.translatesAutoresizingMaskIntoConstraints = false
            field.translatesAutoresizingMaskIntoConstraints = false
            wrapper.addSubview(field)
            NSLayoutConstraint.activate([
                field.topAnchor.constraint(equalTo: wrapper.topAnchor, constant: 2),
                field.bottomAnchor.constraint(equalTo: wrapper.bottomAnchor),
                field.leadingAnchor.constraint(equalTo: wrapper.leadingAnchor, constant: 4),
                field.trailingAnchor.constraint(equalTo: wrapper.trailingAnchor, constant: -4)
            ])
            group.addArrangedSubview(wrapper)
            wrapper.widthAnchor.constraint(equalTo: group.widthAnchor).isActive = true
            footerField = field
        }

        sections.addArrangedSubview(group)
        group.widthAnchor.constraint(equalTo: sections.widthAnchor).isActive = true
        return footerField
    }

    func addCustomView(_ custom: NSView) {
        custom.translatesAutoresizingMaskIntoConstraints = false
        sections.addArrangedSubview(custom)
        custom.widthAnchor.constraint(equalTo: sections.widthAnchor).isActive = true
    }

    func scrollToTop() {
        scroll.contentView.scroll(to: .zero)
        scroll.reflectScrolledClipView(scroll.contentView)
    }
}
