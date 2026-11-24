import AppKit

enum SettingsPane: String, CaseIterable {
    case general, keyboard, history, permissions, about

    var title: String {
        switch self {
        case .general: return L("通用")
        case .keyboard: return L("快捷键")
        case .history: return L("历史")
        case .permissions: return L("权限")
        case .about: return L("关于")
        }
    }

    var symbol: String {
        switch self {
        case .general: return "switch.2"
        case .keyboard: return "keyboard"
        case .history: return "clipboard"
        case .permissions: return "checkmark.shield"
        case .about: return "info.circle"
        }
    }

    var searchKeywords: String {
        switch self {
        case .general:
            return "通用 基本 语言 中文 english 启动 登录 外观 深色 浅色 背景 图片 不透明度 粘贴 纯文本 general language login appearance dark light background opacity paste plain"
        case .keyboard:
            return "快捷键 热键 面板 确认 回车 数字 正则 搜索 语法 shortcut hotkey confirm number regex search syntax"
        case .history:
            return "历史 保留 条数 暂停 图片 文字 识别 搜索 ocr 排除 忽略 密码 钥匙串 清空 数据库 存储 history limit pause image text recognize search exclude ignore password keychain clear storage"
        case .permissions:
            return "权限 系统权限 剪贴板 辅助功能 登录项 隐私 permissions clipboard accessibility login privacy"
        case .about:
            return "关于 版本 诊断 错误 日志 目录 about version diagnostics error log folder"
        }
    }

    static var sidebarSections: [(title: String, panes: [SettingsPane])] {
        [
            (L("通用"), [.general, .permissions]),
            (L("功能"), [.history, .keyboard]),
            (L("其他"), [.about])
        ]
    }
}

struct SettingsActions {
    let suspendShortcut: () throws -> Void
    let resumeShortcut: () throws -> Void
    let clearHistory: () -> Void
    let ocrProgress: () -> (indexed: Int, total: Int)
    let report: (String, Error) -> Void
}

/// 顶栏前进/后退胶囊导航控件。
private final class HistoryNavigationPill: NSView {
    let backButton = NSButton()
    let forwardButton = NSButton()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        for (button, symbol, label) in [
            (backButton, "chevron.left", L("返回")),
            (forwardButton, "chevron.right", L("前进"))
        ] {
            button.translatesAutoresizingMaskIntoConstraints = false
            button.isBordered = false
            button.title = ""
            button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            button.imagePosition = .imageOnly
            button.symbolConfiguration = .init(pointSize: 12, weight: .semibold)
            button.setAccessibilityLabel(label)
            addSubview(button)
        }

        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 28),
            widthAnchor.constraint(equalToConstant: 60),
            backButton.leadingAnchor.constraint(equalTo: leadingAnchor),
            backButton.topAnchor.constraint(equalTo: topAnchor),
            backButton.bottomAnchor.constraint(equalTo: bottomAnchor),
            backButton.widthAnchor.constraint(equalToConstant: 30),
            forwardButton.leadingAnchor.constraint(equalTo: backButton.trailingAnchor),
            forwardButton.trailingAnchor.constraint(equalTo: trailingAnchor),
            forwardButton.topAnchor.constraint(equalTo: topAnchor),
            forwardButton.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        updateButtonTints()
    }

    required init?(coder: NSCoder) { fatalError("不支持从归档创建导航控件。") }

    func updateButtonTints() {
        backButton.contentTintColor = backButton.isEnabled ? .labelColor : .tertiaryLabelColor
        forwardButton.contentTintColor = forwardButton.isEnabled ? .labelColor : .tertiaryLabelColor
    }

    override func draw(_ dirtyRect: NSRect) {
        let pixel = 1 / (window?.backingScaleFactor ?? 1)
        let rect = bounds.insetBy(dx: pixel / 2, dy: pixel / 2)
        guard !rect.isEmpty else { return }
        let radius = rect.height / 2
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        let fill = usesDarkAppearance
            ? NSColor.white.withAlphaComponent(0.06)
            : NSColor.black.withAlphaComponent(0.03)
        let stroke = usesDarkAppearance
            ? NSColor.white.withAlphaComponent(0.11)
            : NSColor.black.withAlphaComponent(0.08)
        fill.setFill()
        path.fill()
        stroke.setStroke()
        path.lineWidth = pixel
        path.stroke()
        stroke.setFill()
        NSRect(x: floor(bounds.midX), y: 6, width: pixel, height: bounds.height - 12).fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateButtonTints()
        needsDisplay = true
    }
}

/// 详情区底布视图：作为窗口默认第一响应者，避免打开设置时侧栏搜索框自带蓝色焦点框。
private final class SettingsDetailCanvasView: NSView {
    override var acceptsFirstResponder: Bool { true }
    override var focusRingType: NSFocusRingType {
        get { .none }
        set {}
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.controlBackgroundColor.setFill()
        dirtyRect.fill()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

@MainActor
private final class SettingsDetailController: NSViewController {
    let navPill = HistoryNavigationPill()
    private let titleLabel = NSTextField(labelWithString: "")
    private let pageContainer = NSView()
    private(set) var currentPage: SettingsPage?

    override func loadView() {
        let root = SettingsDetailCanvasView(frame: NSRect(x: 0, y: 0, width: 516, height: 560))

        let header = SettingsDragArea()
        header.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(header)

        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .labelColor
        header.addSubview(navPill)
        header.addSubview(titleLabel)

        let divider = SettingsHairlineView(horizontalInset: 0)
        root.addSubview(divider)

        pageContainer.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(pageContainer)

        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: root.topAnchor),
            header.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            header.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            header.heightAnchor.constraint(equalToConstant: 52),
            navPill.leadingAnchor.constraint(equalTo: header.leadingAnchor, constant: 20),
            navPill.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            titleLabel.leadingAnchor.constraint(equalTo: navPill.trailingAnchor, constant: 14),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: header.trailingAnchor, constant: -20),
            titleLabel.centerYAnchor.constraint(equalTo: header.centerYAnchor),
            divider.topAnchor.constraint(equalTo: header.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pageContainer.topAnchor.constraint(equalTo: divider.bottomAnchor),
            pageContainer.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            pageContainer.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            pageContainer.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])
        view = root
    }

    func show(_ page: SettingsPage, title: String) {
        titleLabel.stringValue = title
        if currentPage === page { return }
        currentPage?.view.removeFromSuperview()
        currentPage?.removeFromParent()
        addChild(page)
        pageContainer.addSubview(page.view)
        page.view.pinEdges(to: pageContainer)
        currentPage = page
        page.scrollToTop()
    }
}

@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    private let panes: SettingsPanes
    private let split = NSSplitViewController()
    private let sidebar: SettingsSidebarController
    private let detail = SettingsDetailController()
    private var permissionTimer: Timer?
    private var history: [SettingsPane]
    private var historyIndex = 0
    private(set) var selectedPane: SettingsPane

    var currentPageView: NSView? { detail.currentPage?.view }

    init(settings: AppSettings, background: PanelBackgroundStore, directory: URL,
         actions: SettingsActions, selectedPane: SettingsPane = .general) {
        self.panes = SettingsPanes(settings: settings, background: background, directory: directory, actions: actions)
        self.selectedPane = selectedPane
        self.history = [selectedPane]
        self.sidebar = SettingsSidebarController(selected: selectedPane)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 730, height: 560),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        super.init(window: window)
        window.minSize = NSSize(width: 620, height: 440)
        window.isReleasedWhenClosed = false
        window.title = L("ClipNest 设置")
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.delegate = self

        let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebar)
        sidebarItem.canCollapse = false
        sidebarItem.minimumThickness = 200
        sidebarItem.maximumThickness = 240
        sidebarItem.holdingPriority = .defaultHigh

        let detailItem = NSSplitViewItem(viewController: detail)
        detailItem.minimumThickness = 420

        split.addSplitViewItem(sidebarItem)
        split.addSplitViewItem(detailItem)
        window.contentViewController = split

        sidebar.onSelect = { [weak self] pane, record in self?.selectPane(pane, recordHistory: record) }
        detail.navPill.backButton.target = self
        detail.navPill.backButton.action = #selector(goBack)
        detail.navPill.forwardButton.target = self
        detail.navPill.forwardButton.action = #selector(goForward)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidActivate),
            name: NSApplication.didBecomeActiveNotification,
            object: NSApp
        )
        selectPane(selectedPane, recordHistory: false)
        window.initialFirstResponder = detail.view
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("不支持从归档创建设置窗口。") }

    deinit {
        NotificationCenter.default.removeObserver(self)
        permissionTimer?.invalidate()
    }

    override func showWindow(_ sender: Any?) {
        let wasVisible = window?.isVisible == true
        super.showWindow(sender)
        if !wasVisible { window?.makeFirstResponder(detail.view) }
    }

    func selectPane(_ pane: SettingsPane, recordHistory: Bool = true) {
        if pane == selectedPane && detail.currentPage != nil {
            sidebar.ensureVisible(pane)
            return
        }
        if recordHistory && pane != selectedPane {
            if historyIndex < history.count - 1 {
                history.removeSubrange((historyIndex + 1)...)
            }
            history.append(pane)
            historyIndex = history.count - 1
        }
        selectedPane = pane
        sidebar.ensureVisible(pane)
        sidebar.setSelected(pane)
        detail.show(panes.page(for: pane), title: pane.title)
        updateNavigationButtons()
        refresh()
    }

    func refresh() {
        panes.refresh(selectedPane)
        if window?.isVisible == true && selectedPane == .permissions {
            if permissionTimer == nil {
                let timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.panes.refresh(.permissions) }
                }
                timer.tolerance = 0.1
                permissionTimer = timer
            }
        } else { stopTimer() }
    }

    func refreshOCRStatus() {
        if window?.isVisible == true && selectedPane == .history {
            panes.refreshOCRStatus()
        }
    }

    func windowDidBecomeKey(_ notification: Notification) { refresh() }
    @objc private func applicationDidActivate() { if window?.isVisible == true { refresh() } }
    func windowWillClose(_ notification: Notification) { stopTimer() }

    @objc private func goBack() {
        guard historyIndex > 0 else { return }
        historyIndex -= 1
        selectPane(history[historyIndex], recordHistory: false)
    }

    @objc private func goForward() {
        guard historyIndex + 1 < history.count else { return }
        historyIndex += 1
        selectPane(history[historyIndex], recordHistory: false)
    }

    private func updateNavigationButtons() {
        detail.navPill.backButton.isEnabled = historyIndex > 0
        detail.navPill.forwardButton.isEnabled = historyIndex + 1 < history.count
        detail.navPill.updateButtonTints()
    }

    private func stopTimer() {
        permissionTimer?.invalidate()
        permissionTimer = nil
    }
}
