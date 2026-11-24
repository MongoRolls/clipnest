import AppKit
import Darwin

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let service: HistoryService
    private let directory: URL
    private let languageResources: URL?
    private let settings: AppSettings
    private let background: PanelBackgroundStore
    private let errorLog: ErrorLog
    private var lockFD: Int32 = -1
    private var statusItem: NSStatusItem?
    private var panel: HistoryPanelController?
    private var settingsController: SettingsWindowController?
    private lazy var hotKey = HotKey { [weak self] in self?.showWindow(nil) }
    private var retryHotKey = false

    init(clipboard: ClipboardAccess = ClipboardAccess(), directory: URL = AppPaths.defaultDirectory,
         defaults: UserDefaults = .standard, languageResources: URL? = AppResources.languageURL) {
        self.languageResources = languageResources
        L10n.select(AppSettings.language(in: defaults), resources: languageResources)
        let log = ErrorLog(directory: directory)
        self.service = HistoryService(clipboard: clipboard, recoveryURL: AppPaths(directory: directory).historyDatabase, report: log.report)
        self.directory = directory
        self.settings = AppSettings(defaults: defaults)
        self.background = PanelBackgroundStore(directory: directory)
        self.errorLog = log
        super.init()
        settings.beforeKeyboardChange = { [unowned self] value in
            try self.hotKey.register(value.open)
            self.retryHotKey = false
        }
        settings.applyHistoryLimit = service.setHistoryLimit
        settings.onChange = { [weak self] key in self?.settingsChanged(key) }
        background.onChange = { [weak self] in
            guard let self else { return }
            self.panel?.updateBackground(self.background.image, intensity: self.settings.backgroundIntensity)
            self.settingsController?.refresh()
        }
        service.observeChanges(owner: self) { [weak self] change in
            guard let self, change != .state else { return }
            self.settingsController?.refreshOCRStatus()
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let paths = AppPaths(directory: directory)
            lockFD = open(paths.instanceLock.path, O_CREAT | O_RDWR, 0o600)
            guard lockFD >= 0 else { throw AppError(L("无法创建单实例锁（%d）。", errno)) }
            if flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
                guard errno == EWOULDBLOCK else { throw AppError(L("无法锁定应用实例（%d）。", errno)) }
                for app in NSRunningApplication.runningApplications(withBundleIdentifier: AppPaths.bundleIdentifier) where app.processIdentifier != getpid() {
                    app.activate(options: [])
                }
                NSApp.terminate(nil)
                return
            }
            createMenu()
            let limit = settings.historyLimit
            startPanel(showOnLaunch: !SystemAccess.isLoginLaunch) {
                try HistoryStore(url: paths.historyDatabase, key: KeyProvider.historyKey(), historyLimit: limit)
            }
            registerHotKey()
        } catch {
            report(L("ClipNest 无法启动"), error)
            let alert = NSAlert()
            alert.alertStyle = .critical
            alert.messageText = L("ClipNest 无法启动")
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    /// 注册失败时保留重试标记：切换语言会重新尝试，修改快捷键成功后清除标记。
    private func registerHotKey() {
        do {
            try hotKey.register(settings.keyboard.open)
            retryHotKey = false
        } catch {
            report(L("注册快捷键"), error)
            retryHotKey = true
        }
    }

    private func applyCapturePolicy() {
        service.updateCapturePolicy(paused: settings.paused, ignoredBundleIDs: settings.ignoredBundleIDs)
    }

    func startPanel(showOnLaunch: Bool = true, openStore: @escaping () throws -> HistoryStore) {
        configurePanel()
        applyCapturePolicy()
        service.setAutoOCREnabled(settings.imageOCR)
        if let error = settings.keyboardLoadError { report(L("读取按键设置"), error) }
        if let error = background.loadError { report(L("读取面板背景"), error) }
        updateStatusButton()
        if showOnLaunch { showWindow(nil) }
        service.start(openStore: openStore)
    }

    private func configurePanel() {
        if let panel { service.removeObserver(panel) }
        let panel = HistoryPanelController(service: service, settings: settings)
        self.panel = panel
        panel.updateBackground(background.image, intensity: settings.backgroundIntensity)
        panel.onShowSettings = { [weak self] in self?.showSettings(nil) }
        panel.onError = { [weak self] in self?.report($0, $1) }
        panel.onOpenErrorLog = { [weak self] in
            guard let self else { return }
            if !NSWorkspace.shared.open(AppPaths(directory: self.directory).errorLog) {
                self.report(L("打开错误日志"), AppError(L("无法打开错误日志")))
            }
        }
    }

    private func createMenu() {
        let menu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: L("显示 ClipNest"), action: #selector(showWindow(_:)), keyEquivalent: "").target = self
        let settingsItem = appMenu.addItem(withTitle: L("设置…"), action: #selector(showSettings(_:)), keyEquivalent: "")
        PanelShortcut.settings.apply(to: settingsItem)
        settingsItem.target = self
        let quitItem = appMenu.addItem(withTitle: L("退出 ClipNest"), action: #selector(quit), keyEquivalent: "")
        PanelShortcut.quit.apply(to: quitItem)
        quitItem.target = self
        appItem.submenu = appMenu
        menu.addItem(appItem)
        let edit = NSMenuItem()
        edit.title = L("编辑")
        let editMenu = NSMenu(title: L("编辑"))
        for (title, action, key) in [(L("剪切"), "cut:", "x"), (L("复制"), "copy:", "c"), (L("粘贴"), "paste:", "v"), (L("全选"), "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        edit.submenu = editMenu
        menu.addItem(edit)
        NSApp.mainMenu = menu
        if statusItem == nil { statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength) }
        statusItem?.menu = statusMenu
    }

    private(set) lazy var statusMenu = makeStatusMenu()

    private func makeStatusMenu() -> NSMenu {
        let menu = NSMenu()
        menu.addItem(withTitle: L("显示历史"), action: #selector(showWindow(_:)), keyEquivalent: "")
        let pause = menu.addItem(withTitle: L("暂停记录"), action: #selector(togglePause), keyEquivalent: "")
        pause.state = settings.paused ? .on : .off
        let settingsItem = menu.addItem(withTitle: L("设置…"), action: #selector(showSettings(_:)), keyEquivalent: "")
        PanelShortcut.settings.apply(to: settingsItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: L("退出 ClipNest"), action: #selector(quit), keyEquivalent: "")
        for item in menu.items where !item.isSeparatorItem { item.target = self }
        return menu
    }

    @objc func showWindow(_ sender: Any?) { panel?.showWindow(sender) }
    @objc private func togglePause() { settings.paused.toggle() }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(nil)
        return true
    }

    @objc private func showSettings(_ sender: Any?) {
        panel?.hide()
        if settingsController?.window?.isVisible != true {
            settingsController = makeSettingsWindow(selectedPane: .general)
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsController?.showWindow(sender)
        settingsController?.window?.makeKeyAndOrderFront(sender)
    }

    private func makeSettingsWindow(selectedPane: SettingsPane) -> SettingsWindowController {
        let actions = SettingsActions(suspendShortcut: hotKey.suspend, resumeShortcut: hotKey.resume,
                                     clearHistory: { [weak self] in self?.panel?.clearHistory() },
                                     ocrProgress: { [weak self] in self?.service.ocrImageProgress ?? (0, 0) },
                                     report: { [weak self] in self?.report($0, $1) })
        return SettingsWindowController(settings: settings, background: background, directory: directory, actions: actions, selectedPane: selectedPane)
    }

    private func changeLanguage() {
        L10n.select(settings.language, resources: languageResources)
        statusMenu = makeStatusMenu()
        if statusItem != nil { createMenu() }
        let state = panel?.restorationState
        panel?.hide()
        configurePanel()
        if retryHotKey { registerHotKey() }
        if let state { panel?.restore(state) }
        if let previous = settingsController, let window = previous.window, window.isVisible {
            let origin = NSPoint(x: window.frame.minX, y: window.frame.maxY)
            let pane = previous.selectedPane
            previous.close()
            let next = makeSettingsWindow(selectedPane: pane)
            settingsController = next
            next.window?.setFrameTopLeftPoint(origin)
            next.showWindow(nil)
            next.window?.makeKeyAndOrderFront(nil)
        }
        updateStatusButton()
        service.reloadLocalizedSnapshot()
    }

    private func settingsChanged(_ key: AppSettings.Key) {
        switch key {
        case .language:
            changeLanguage()
            return
        case .backgroundIntensity:
            panel?.updateBackground(background.image, intensity: settings.backgroundIntensity)
            return
        case .appearance:
            panel?.updateAppearance()
        case .keyboard:
            retryHotKey = false
            panel?.updateKeyboard(settings.keyboard)
            updateStatusButton()
        case .directPaste:
            panel?.updateAccessibilityBanner()
            panel?.refreshCommands()
        case .plainTextByDefault:
            panel?.refreshCommands()
        case .imageOCR:
            service.setAutoOCREnabled(settings.imageOCR)
            panel?.refreshCommands()
        case .paused, .ignoredBundleIDs:
            applyCapturePolicy()
            statusMenu.items.first { $0.action == #selector(togglePause) }?.state = settings.paused ? .on : .off
            updateStatusButton()
            panel?.updatePausedState()
            panel?.refreshCommands()
        case .historyLimit: break
        }
        settingsController?.refresh()
    }

    private func updateStatusButton() {
        if settings.paused {
            statusItem?.button?.image = NSImage(systemSymbolName: "pause.circle", accessibilityDescription: L("ClipNest 已暂停记录"))
            statusItem?.button?.toolTip = L("ClipNest 已暂停记录")
            return
        }
        statusItem?.button?.image = NSImage(systemSymbolName: "clipboard", accessibilityDescription: L("ClipNest 剪贴板历史"))
        statusItem?.button?.toolTip = "ClipNest · \(settings.keyboard.open.title)"
    }

    private func report(_ action: String, _ error: Error) {
        errorLog.report(action, error)
    }

    @objc private func quit() { NSApp.terminate(nil) }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !service.quitting else { return .terminateLater }
        panel?.cancelPendingActions()
        service.stop { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        service.invalidatePolling()
        hotKey.invalidate()
        if lockFD >= 0 { close(lockFD); lockFD = -1 }
    }
}
