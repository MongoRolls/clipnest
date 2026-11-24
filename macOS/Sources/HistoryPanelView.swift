import AppKit

private final class HistoryPanelHeader: NSView {
    override var mouseDownCanMoveWindow: Bool { true }
}

final class PanelBannerView: NSView {
    let actionButton: NSButton

    init(symbol: String, title text: String, buttonTitle: String, buttonAccessibilityLabel: String) {
        actionButton = NSButton(title: buttonTitle, target: nil, action: nil)
        super.init(frame: .zero)
        let icon = NSImageView()
        icon.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        icon.symbolConfiguration = .init(pointSize: 12, weight: .medium)
        icon.contentTintColor = .systemOrange
        icon.setAccessibilityElement(false)
        let title = NSTextField(labelWithString: text)
        title.font = .systemFont(ofSize: 12, weight: .medium)
        title.textColor = .labelColor
        title.lineBreakMode = .byTruncatingTail
        title.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        actionButton.isBordered = false
        actionButton.font = .systemFont(ofSize: 12, weight: .medium)
        actionButton.attributedTitle = NSAttributedString(string: buttonTitle, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: .medium),
            .foregroundColor: NSColor.controlAccentColor
        ])
        actionButton.setAccessibilityLabel(buttonAccessibilityLabel)
        actionButton.setContentHuggingPriority(.required, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [icon, title, spacer, actionButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 0, right: 8)
        addSubview(stack)
        stack.pinEdges(to: self)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14)
        ])
    }

    required init?(coder: NSCoder) { fatalError("不支持从归档创建横幅视图。") }

    override func draw(_ dirtyRect: NSRect) {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 6, yRadius: 6)
        NSColor.systemOrange.withAlphaComponent(usesDarkAppearance ? 0.20 : 0.14).setFill()
        shape.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
final class HistoryPanelView {
    let window: HistoryWindow
    let surface: HistorySurface
    let search = NSSearchField()
    let pausedBanner = PanelBannerView(symbol: "pause.circle.fill", title: L("已暂停记录"),
                                       buttonTitle: L("恢复"), buttonAccessibilityLabel: L("恢复记录"))
    var resumeButton: NSButton { pausedBanner.actionButton }
    let accessibilityBanner = PanelBannerView(symbol: "hand.raised.fill", title: L("直接粘贴需要辅助功能权限"),
                                              buttonTitle: L("前往授权"), buttonAccessibilityLabel: L("打开辅助功能设置"))
    var grantAccessibilityButton: NSButton { accessibilityBanner.actionButton }
    let table = HistoryTableView()
    let emptyText = NSTextField(wrappingLabelWithString: "")
    let operation = NSTextField(labelWithString: "")
    private let failureBox = NSStackView()
    private let failureReason: NSTextView
    let retryButton = NSButton(title: L("重新加载"), target: nil, action: nil)
    let logButton = NSButton(title: L("打开错误日志"), target: nil, action: nil)
    let archiveButton = NSButton(title: L("归档旧库并重新开始…"), target: nil, action: nil)
    let settingsButton = NSButton()
    let listButton: FooterButton
    let clearButton: FooterButton

    init(listButton: FooterButton, clearButton: FooterButton) {
        self.listButton = listButton
        self.clearButton = clearButton
        window = HistoryWindow(contentRect: NSRect(x: 0, y: 0, width: HistoryLayout.width, height: HistoryLayout.height), styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        window.title = "ClipNest"
        window.minSize = NSSize(width: 360, height: HistoryLayout.minimumHeight)
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.animationBehavior = .none
        window.acceptsMouseMovedEvents = true
        window.hidesOnDeactivate = false
        window.isMovableByWindowBackground = true
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        surface = window.installSurface()
        let root = NSStackView()
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 4
        root.edgeInsets = NSEdgeInsets(top: 10, left: 8, bottom: 10, right: 8)
        surface.addSubview(root)
        root.pinEdges(to: surface)
        search.placeholderString = L("搜索…")
        search.font = .systemFont(ofSize: 14)
        search.setAccessibilityLabel(L("搜索剪贴板历史"))
        search.sendsSearchStringImmediately = true
        let heading = HistoryPanelHeader()
        heading.addSubview(search)
        search.translatesAutoresizingMaskIntoConstraints = false
        // 保留搜索框两侧的拖动区域，输入和划词仍由原生搜索框接收。
        NSLayoutConstraint.activate([
            search.leadingAnchor.constraint(equalTo: heading.leadingAnchor, constant: 8),
            search.trailingAnchor.constraint(equalTo: heading.trailingAnchor, constant: -8),
            search.centerYAnchor.constraint(equalTo: heading.centerYAnchor)
        ])
        heading.heightAnchor.constraint(equalToConstant: 32).isActive = true
        root.addArrangedSubview(heading)
        pausedBanner.isHidden = true
        root.addArrangedSubview(pausedBanner)
        accessibilityBanner.isHidden = true
        root.addArrangedSubview(accessibilityBanner)
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("entry"))
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.style = .plain
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.rowSizeStyle = .custom
        table.setDraggingSourceOperationMask(.move, forLocal: true)
        table.setDraggingSourceOperationMask([], forLocal: false)
        table.verticalMotionCanBeginDrag = true
        table.setAccessibilityLabel(L("剪贴板历史记录"))
        let list = NSScrollView()
        list.documentView = table
        list.hasVerticalScroller = true
        list.hasHorizontalScroller = false
        list.scrollerStyle = .overlay
        list.horizontalScrollElasticity = .none
        list.autohidesScrollers = true
        list.drawsBackground = false
        list.borderType = .noBorder
        let listContainer = NSView()
        emptyText.translatesAutoresizingMaskIntoConstraints = false
        emptyText.textColor = .secondaryLabelColor
        emptyText.font = .systemFont(ofSize: 13)
        emptyText.alignment = .center
        listContainer.addSubview(list)
        listContainer.addSubview(emptyText)
        list.pinEdges(to: listContainer)
        NSLayoutConstraint.activate([
            listContainer.heightAnchor.constraint(greaterThanOrEqualToConstant: 64),
            emptyText.centerYAnchor.constraint(equalTo: listContainer.centerYAnchor),
            emptyText.leadingAnchor.constraint(equalTo: listContainer.leadingAnchor, constant: 20),
            emptyText.trailingAnchor.constraint(equalTo: listContainer.trailingAnchor, constant: -20)
        ])
        root.addArrangedSubview(listContainer)
        let (reasonScroll, failureReason) = NSScrollView.readOnlyText(autohidesScrollers: true)
        self.failureReason = failureReason
        failureBox.orientation = .vertical
        failureBox.spacing = 4
        failureBox.addArrangedSubview(reasonScroll)
        failureBox.addArrangedSubview(NSStackView(views: [retryButton, logButton]))
        failureBox.addArrangedSubview(archiveButton)
        listContainer.addSubview(failureBox)
        failureBox.pinEdges(to: listContainer)
        reasonScroll.widthAnchor.constraint(equalTo: failureBox.widthAnchor).isActive = true
        failureBox.isHidden = true
        operation.font = .systemFont(ofSize: 11)
        operation.textColor = .secondaryLabelColor
        operation.lineBreakMode = .byTruncatingTail
        operation.maximumNumberOfLines = 1
        operation.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        root.addArrangedSubview(operation)
        let separator = NSBox()
        separator.boxType = .separator
        root.addArrangedSubview(separator)
        let quitButton = FooterButton(title: PanelShortcut.quit.menuTitle, shortcut: PanelShortcut.quit.hint,
                                      target: NSApplication.shared, action: #selector(NSApplication.terminate(_:)))
        let settingsTitle = PanelShortcut.settings.menuTitle
        settingsButton.title = ""
        settingsButton.bezelStyle = .accessoryBarAction
        settingsButton.showsBorderOnlyWhileMouseInside = true
        settingsButton.image = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil)
        settingsButton.imagePosition = .imageOnly
        settingsButton.symbolConfiguration = .init(pointSize: 14, weight: .regular)
        settingsButton.toolTip = PanelShortcut.settings.hint
        settingsButton.setAccessibilityLabel(settingsTitle)
        settingsButton.setAccessibilityHelp(L("快捷键 %@", PanelShortcut.settings.hint))
        NSLayoutConstraint.activate([
            settingsButton.widthAnchor.constraint(equalToConstant: 28),
            settingsButton.heightAnchor.constraint(equalToConstant: 26)
        ])
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [listButton, settingsButton, spacer, clearButton, quitButton])
        footer.spacing = 4
        footer.heightAnchor.constraint(equalToConstant: 26).isActive = true
        root.addArrangedSubview(footer)
        // 每一行明确填满面板，避免按按钮的固有宽度收缩。
        for view in root.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: root.widthAnchor, constant: -16).isActive = true
        }
    }

    func showFailure(_ error: Error?, canRetry: Bool, canArchive: Bool) {
        failureBox.isHidden = error == nil
        table.enclosingScrollView?.isHidden = error != nil
        guard let error else { return }
        emptyText.isHidden = true
        let reason = L("无法加载历史记录。%@", error.localizedDescription)
        if failureReason.string != reason { failureReason.string = reason }
        retryButton.isEnabled = canRetry
        archiveButton.isEnabled = canArchive
    }
}
