import AppKit

/// 侧栏导航项按钮：沿用 NSButton 点击与辅助功能语义，绘制圆角选中与悬停底纹。
private final class SidebarItemButton: NSButton {
    let pane: SettingsPane
    private let iconView = NSImageView()
    private let titleField = NSTextField(labelWithString: "")
    private var hovered = false { didSet { needsDisplay = true } }
    private var tracker: NSTrackingArea?
    var isSelected = false {
        didSet {
            titleField.font = .systemFont(ofSize: 13, weight: isSelected ? .medium : .regular)
            needsDisplay = true
        }
    }
    var onSelect: ((SettingsPane) -> Void)?

    init(pane: SettingsPane) {
        self.pane = pane
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        isBordered = false
        title = ""
        setButtonType(.momentaryChange)
        target = self
        action = #selector(trigger)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.image = NSImage(systemSymbolName: pane.symbol, accessibilityDescription: nil)
        iconView.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        iconView.contentTintColor = .controlAccentColor
        iconView.setAccessibilityElement(false)

        titleField.translatesAutoresizingMaskIntoConstraints = false
        titleField.stringValue = pane.title
        titleField.font = .systemFont(ofSize: 13, weight: .regular)
        titleField.textColor = .labelColor
        titleField.lineBreakMode = .byTruncatingTail

        addSubview(iconView)
        addSubview(titleField)
        setAccessibilityLabel(pane.title)

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 32),
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
            titleField.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 8),
            titleField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            titleField.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    required init?(coder: NSCoder) { fatalError("不支持从归档创建侧栏按钮。") }

    @objc private func trigger() { onSelect?(pane) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracker { removeTrackingArea(tracker) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracker = area
    }

    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func draw(_ dirtyRect: NSRect) {
        let fill: NSColor?
        if isSelected {
            fill = usesDarkAppearance
                ? NSColor.white.withAlphaComponent(0.12)
                : NSColor.black.withAlphaComponent(0.075)
        } else if hovered {
            fill = usesDarkAppearance
                ? NSColor.white.withAlphaComponent(0.055)
                : NSColor.black.withAlphaComponent(0.038)
        } else {
            fill = nil
        }
        if let fill {
            fill.setFill()
            NSBezierPath(roundedRect: bounds, xRadius: 8, yRadius: 8).fill()
        }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// 设置窗口左侧分组导航栏，支持按中英文关键词即时过滤分页。
@MainActor
final class SettingsSidebarController: NSViewController, NSSearchFieldDelegate {
    private let searchField = NSSearchField()
    private let listStack = NSStackView()
    private let emptyLabel = NSTextField(labelWithString: L("没有匹配的设置"))
    private var itemButtons: [SettingsPane: SidebarItemButton] = [:]
    private var sectionViews: [(header: NSView, panes: [SettingsPane])] = []
    private var selected: SettingsPane
    var onSelect: ((SettingsPane, Bool) -> Void)?

    init(selected: SettingsPane) {
        self.selected = selected
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("不支持从归档创建设置侧栏。") }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 214, height: 560))

        let dragArea = SettingsDragArea()
        dragArea.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(dragArea)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = L("搜索")
        searchField.sendsSearchStringImmediately = true
        searchField.delegate = self
        searchField.setAccessibilityLabel(L("搜索设置"))
        root.addSubview(searchField)

        let scroll = NSScrollView()
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay

        let document = SettingsFlippedView()
        document.translatesAutoresizingMaskIntoConstraints = false
        listStack.orientation = .vertical
        listStack.alignment = .leading
        listStack.spacing = 2
        listStack.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(listStack)
        scroll.documentView = document
        root.addSubview(scroll)

        for (sectionIndex, section) in SettingsPane.sidebarSections.enumerated() {
            let headerLabel = NSTextField(labelWithString: section.title)
            headerLabel.font = .systemFont(ofSize: 11, weight: .semibold)
            headerLabel.textColor = .secondaryLabelColor
            let headerContainer = NSView()
            headerContainer.translatesAutoresizingMaskIntoConstraints = false
            headerLabel.translatesAutoresizingMaskIntoConstraints = false
            headerContainer.addSubview(headerLabel)
            NSLayoutConstraint.activate([
                headerLabel.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 18),
                headerLabel.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor, constant: -10),
                headerLabel.topAnchor.constraint(equalTo: headerContainer.topAnchor, constant: sectionIndex == 0 ? 4 : 14),
                headerLabel.bottomAnchor.constraint(equalTo: headerContainer.bottomAnchor, constant: -4)
            ])
            listStack.addArrangedSubview(headerContainer)
            headerContainer.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true

            for pane in section.panes {
                let button = SidebarItemButton(pane: pane)
                button.isSelected = pane == selected
                button.onSelect = { [weak self] chosen in self?.onSelect?(chosen, true) }
                let rowWrapper = NSView()
                rowWrapper.translatesAutoresizingMaskIntoConstraints = false
                rowWrapper.addSubview(button)
                NSLayoutConstraint.activate([
                    button.leadingAnchor.constraint(equalTo: rowWrapper.leadingAnchor, constant: 10),
                    button.trailingAnchor.constraint(equalTo: rowWrapper.trailingAnchor, constant: -10),
                    button.topAnchor.constraint(equalTo: rowWrapper.topAnchor),
                    button.bottomAnchor.constraint(equalTo: rowWrapper.bottomAnchor)
                ])
                listStack.addArrangedSubview(rowWrapper)
                rowWrapper.widthAnchor.constraint(equalTo: listStack.widthAnchor).isActive = true
                itemButtons[pane] = button
            }
            sectionViews.append((headerContainer, section.panes))
        }

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        root.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            dragArea.topAnchor.constraint(equalTo: root.topAnchor),
            dragArea.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            dragArea.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            dragArea.heightAnchor.constraint(equalToConstant: 44),
            searchField.topAnchor.constraint(equalTo: dragArea.bottomAnchor),
            searchField.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            searchField.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scroll.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 10),
            scroll.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            listStack.topAnchor.constraint(equalTo: document.topAnchor, constant: 2),
            listStack.leadingAnchor.constraint(equalTo: document.leadingAnchor),
            listStack.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            listStack.bottomAnchor.constraint(equalTo: document.bottomAnchor, constant: -12),
            emptyLabel.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 24),
            emptyLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            emptyLabel.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16)
        ])
        view = root
    }

    func setSelected(_ pane: SettingsPane) {
        selected = pane
        for (item, button) in itemButtons {
            button.isSelected = item == pane
        }
    }

    /// 历史导航切回被当前搜索词隐藏的分页时，清空过滤以保持侧栏状态一致。
    func ensureVisible(_ pane: SettingsPane) {
        guard itemButtons[pane]?.superview?.isHidden == true else { return }
        searchField.stringValue = ""
        applyFilter(autoSelect: false)
    }

    func controlTextDidChange(_ obj: Notification) {
        applyFilter(autoSelect: true)
    }

    private func applyFilter(autoSelect: Bool) {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let terms = query.split(whereSeparator: \.isWhitespace).map(String.init)
        var firstVisible: SettingsPane?
        var selectedVisible = false
        for section in sectionViews {
            var sectionHasVisible = false
            for pane in section.panes {
                let haystack = (pane.title + " " + pane.searchKeywords).lowercased()
                let matched = terms.isEmpty || terms.allSatisfy { haystack.contains($0) }
                itemButtons[pane]?.superview?.isHidden = !matched
                if matched {
                    sectionHasVisible = true
                    if firstVisible == nil { firstVisible = pane }
                    if pane == selected { selectedVisible = true }
                }
            }
            section.header.isHidden = !sectionHasVisible
        }
        emptyLabel.isHidden = firstVisible != nil
        if autoSelect, !selectedVisible, let firstVisible {
            onSelect?(firstVisible, false)
        }
    }
}
