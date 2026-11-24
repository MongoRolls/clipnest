import AppKit
import ServiceManagement

@MainActor
final class SettingsPanes: NSObject {
    private let settings: AppSettings
    private let background: PanelBackgroundControls
    private let paths: AppPaths
    private var pages: [SettingsPane: SettingsPage] = [:]
    private var sizeRequest = RequestGuard()
    private let actions: SettingsActions

    private let language = NSPopUpButton()
    private let appearance = NSPopUpButton()
    private lazy var recorder = ShortcutRecorder(shortcut: settings.keyboard.open)
    private let confirmation = NSPopUpButton(), numbers = NSPopUpButton()
    private let sizeText = NSTextField(labelWithString: "—")

    private lazy var login = toggle(L("登录时自动启动 ClipNest"), #selector(changeLogin))
    private lazy var loginPreferences = button(L("打开登录项设置"), #selector(openLogin))
    private var generalCard: SettingsCardView?
    private var loginApprovalRow: SettingsRowView?
    private var appearanceCard: SettingsCardView?

    private let clipboardState = SettingsStatusBadgeView(label: L("读取剪贴板状态"))
    private let accessibilityState = SettingsStatusBadgeView(label: L("辅助功能状态"))
    private let loginState = SettingsStatusBadgeView(label: L("登录项状态"))
    private var clipboardRow: SettingsRowView?

    private lazy var paste = toggle(L("直接粘贴到当前应用"), #selector(changePaste))
    private lazy var grantPaste = button(L("前往授权…"), #selector(openAccessibility))
    private lazy var plainText = toggle(L("默认复制为纯文本"), #selector(changePlainText))

    private let limit = NSPopUpButton()
    private lazy var pause = toggle(L("暂停记录"), #selector(changePause))
    private lazy var imageOCR = toggle(L("搜索图片中的文字"), #selector(changeImageOCR))
    private var ocrFooter: NSTextField?
    private lazy var excludedApps = SettingsExcludedAppsView(settings: settings, report: actions.report)

    private lazy var openLogButton = button(L("打开错误日志"), #selector(openLog))
    private var logRow: SettingsRowView?

    init(settings: AppSettings, background: PanelBackgroundStore, directory: URL, actions: SettingsActions) {
        self.settings = settings
        self.background = PanelBackgroundControls(settings: settings, store: background, report: actions.report)
        self.paths = AppPaths(directory: directory)
        self.actions = actions
        super.init()
        self.background.onLayoutChange = { [weak self] in
            self?.appearanceCard?.updateDividers()
        }
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        let control = NSButton(title: title, target: self, action: action)
        control.bezelStyle = .rounded
        control.setAccessibilityLabel(title)
        return control
    }

    private func toggle(_ label: String, _ action: Selector) -> NSSwitch {
        let control = NSSwitch()
        control.controlSize = .small
        control.target = self
        control.action = action
        control.setAccessibilityLabel(label)
        return control
    }

    private func fill(_ picker: NSPopUpButton, _ titles: [String], label: String) {
        picker.removeAllItems()
        picker.addItems(withTitles: titles)
        picker.setAccessibilityLabel(label)
    }

    func page(for pane: SettingsPane) -> SettingsPage {
        if let page = pages[pane] { return page }
        let page = SettingsPage()
        switch pane {
        case .general: buildGeneral(page)
        case .keyboard: buildKeyboard(page)
        case .history: buildHistory(page)
        case .permissions: buildPermissions(page)
        case .about: buildAbout(page)
        }
        pages[pane] = page
        return page
    }

    private func buildGeneral(_ page: SettingsPage) {
        fill(language, AppLanguage.allCases.map(\.title), label: L("界面语言"))
        language.target = self
        language.action = #selector(changeLanguage)

        let (general, _) = page.addSection(title: L("基本")) { card in
            card.addRow(SettingsRowView(
                title: L("语言"),
                subtitle: L("系统菜单等文字会在下次启动时更新。"),
                trailing: [language]
            ))
            card.addRow(SettingsRowView(
                title: L("登录时自动启动 ClipNest"),
                subtitle: L("控制 ClipNest 是否随登录启动。"),
                trailing: [login]
            ))
            let approval = SettingsRowView(
                title: L("需要批准"),
                subtitle: L("需要在系统设置中批准此登录项。"),
                trailing: [loginPreferences]
            )
            approval.isHidden = true
            loginApprovalRow = approval
            card.addRow(approval)
        }
        generalCard = general

        fill(appearance, PanelAppearance.allCases.map(\.title), label: L("面板外观"))
        appearance.target = self
        appearance.action = #selector(changeAppearance)

        let (appearanceSection, _) = page.addSection(title: L("外观")) { card in
            card.addRow(SettingsRowView(
                title: L("面板外观"),
                subtitle: L("历史、收藏与详情预览均遵循此设置。"),
                trailing: [appearance]
            ))
            card.addRow(background.imageRow)
            card.addRow(background.opacityRow)
        }
        appearanceCard = appearanceSection
        appearanceSection.updateDividers()

        page.addSection(title: L("选中记录")) { card in
            card.addRow(SettingsRowView(
                title: L("直接粘贴到当前应用"),
                subtitle: L("直接粘贴需要辅助功能权限。"),
                trailing: [grantPaste, paste]
            ))
            card.addRow(SettingsRowView(
                title: L("默认复制为纯文本"),
                subtitle: L("开启后文本记录默认只保留纯文本；按 Shift + 确认复制键可保留原格式。"),
                trailing: [plainText]
            ))
        }
    }

    private func buildHistory(_ page: SettingsPage) {
        fill(limit, AppSettings.historyLimits.map { L("%d 条", $0) }, label: L("保留条数"))
        limit.target = self
        limit.action = #selector(changeLimit)

        page.addSection(title: L("记录")) { card in
            card.addRow(SettingsRowView(
                title: L("保留条数"),
                subtitle: L("调低上限会立即清理较早的普通历史，收藏记录会保留。"),
                trailing: [limit]
            ))
            card.addRow(SettingsRowView(
                title: L("暂停记录"),
                subtitle: L("开启后暂时停止收录新的剪贴板内容。"),
                trailing: [pause]
            ))
        }

        let (_, footer) = page.addSection(
            title: L("图片文字搜索"),
            footer: L("在本地识别图片中的文字以便搜索，结果加密保存在历史数据库中。")
        ) { card in
            card.addRow(SettingsRowView(
                icon: "text.viewfinder",
                title: L("搜索图片中的文字"),
                subtitle: L("空闲时在这台 Mac 上识别。"),
                trailing: [imageOCR]
            ))
        }
        ocrFooter = footer

        page.addSection(
            title: L("已排除的 App"),
            content: excludedApps,
            footer: L("不会记录来自这些 App 的拷贝内容。")
        )

        sizeText.font = .monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
        sizeText.textColor = .secondaryLabelColor
        sizeText.setAccessibilityLabel(L("数据库占用大小"))

        page.addSection(title: L("存储")) { card in
            card.addRow(SettingsRowView(
                title: L("数据库占用"),
                subtitle: L("本地加密存储的历史记录与图片索引。"),
                trailing: [sizeText, button(L("在访达中显示"), #selector(revealDirectory))]
            ))
            card.addRow(SettingsRowView(
                title: L("清空历史"),
                subtitle: L("收藏记录和当前系统剪贴板不会被清空。"),
                trailing: [button(L("清空历史…"), #selector(clearHistory))]
            ))
        }
    }

    private func buildKeyboard(_ page: SettingsPage) {
        fill(confirmation, ConfirmationKey.allCases.map(\.title), label: L("确认复制"))
        fill(numbers, HistoryShortcut.allCases.map { "\($0.title) + 1–9" }, label: L("数字选取"))
        for picker in [confirmation, numbers] {
            picker.target = self
            picker.action = #selector(saveKeyboard)
        }
        recorder.onBegin = actions.suspendShortcut
        recorder.onEnd = actions.resumeShortcut
        recorder.onCommit = { [weak self] shortcut in
            guard let self else { return }
            var keyboard = self.settings.keyboard
            keyboard.open = shortcut
            try self.settings.setKeyboard(keyboard)
        }
        recorder.onError = { [weak self] in self?.actions.report(L("注册快捷键"), $0) }

        page.addSection(title: L("全局与选取")) { card in
            card.addRow(SettingsRowView(
                title: L("打开历史面板"),
                subtitle: L("点击后按下新快捷键，按 Esc 取消。"),
                trailing: [recorder]
            ))
            card.addRow(SettingsRowView(title: L("确认复制"), trailing: [confirmation]))
            card.addRow(SettingsRowView(title: L("数字选取"), trailing: [numbers]))
            card.addRow(SettingsRowView(
                title: L("恢复默认快捷键"),
                trailing: [button(L("恢复默认"), #selector(resetKeyboard))]
            ))
        }

        let shortcutRows: [(String, String)] = [
            (L("搜索"), PanelShortcut.search.hint),
            (L("查看内容"), "\(L("空格")) / \(PanelShortcut.preview.hint)"),
            (L("收藏/取消"), PanelShortcut.favorite.hint),
            (L("切换收藏"), PanelShortcut.lists.hint),
            (L("删除所选"), PanelShortcut.delete.hint),
            (L("清空历史"), PanelShortcut.clear.hint),
            (L("关闭"), PanelShortcut.close.hint)
        ]
        page.addSection(
            title: L("面板内快捷键"),
            footer: L("Shift + 确认复制键：切换纯文本/原格式复制，或提取图中文字。")
        ) { card in
            for (title, key) in shortcutRows {
                card.addRow(SettingsRowView(title: title, trailing: [SettingsKeycapView(key)]))
            }
        }

        let syntaxRows: [(String, String)] = [
            ("type:", L("按类型筛选（type:text、type:image、type:file）")),
            ("@", L("按来源应用筛选（如 @Safari、@访达）")),
            ("/", L("使用正则表达式搜索（支持 i / m / s 标志）")),
            (">", L("执行面板命令（如 >pause、>plain、>ocr）"))
        ]
        page.addSection(title: L("搜索语法")) { card in
            for (prefix, detail) in syntaxRows {
                card.addRow(SettingsRowView(title: detail, trailing: [SettingsKeycapView(prefix, monospaced: true)]))
            }
        }
    }

    private func buildPermissions(_ page: SettingsPage) {
        page.addSection(title: L("系统权限")) { card in
            let clipboard = SettingsRowView(
                title: L("读取剪贴板"),
                titleBadge: clipboardState,
                subtitle: L("用于记录复制的内容。"),
                trailing: [button(L("打开隐私与安全性"), #selector(openClipboard))]
            )
            clipboardRow = clipboard
            card.addRow(clipboard)
            card.addRow(SettingsRowView(
                title: L("辅助功能"),
                titleBadge: accessibilityState,
                subtitle: L("直接粘贴到当前应用时需要此权限。"),
                trailing: [button(L("打开辅助功能设置"), #selector(openAccessibility))]
            ))
            card.addRow(SettingsRowView(
                title: L("登录项"),
                titleBadge: loginState,
                subtitle: L("控制 ClipNest 是否随登录启动。"),
                trailing: [button(L("打开登录项设置"), #selector(openLogin))]
            ))
        }
    }

    private func buildAbout(_ page: SettingsPage) {
        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = NSApp.applicationIconImage
        icon.imageScaling = .scaleProportionallyUpOrDown
        icon.setAccessibilityElement(false)
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 64),
            icon.heightAnchor.constraint(equalToConstant: 64)
        ])

        let name = NSTextField(labelWithString: "ClipNest")
        name.font = .systemFont(ofSize: 18, weight: .semibold)

        let shortVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? L("未知")
        let buildVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        let versionText = buildVersion.map { "\(L("版本")) \(shortVersion) (\($0))" } ?? "\(L("版本")) \(shortVersion)"
        let version = NSTextField(labelWithString: versionText)
        version.font = .systemFont(ofSize: 12.5)
        version.textColor = .secondaryLabelColor

        let tagline = NSTextField(labelWithString: L("本地加密的 macOS 剪贴板历史工具"))
        tagline.font = .systemFont(ofSize: 12)
        tagline.textColor = .tertiaryLabelColor

        let hero = NSStackView(views: [icon, name, version, tagline])
        hero.orientation = .vertical
        hero.alignment = .centerX
        hero.spacing = 4
        hero.setCustomSpacing(10, after: icon)
        hero.edgeInsets = NSEdgeInsets(top: 10, left: 0, bottom: 6, right: 0)
        page.addCustomView(hero)

        page.addSection(title: L("诊断")) { card in
            let log = SettingsRowView(
                title: L("错误日志"),
                subtitle: L("仅记录时间、操作名与错误代码，不记录剪贴板内容。"),
                trailing: [openLogButton]
            )
            logRow = log
            card.addRow(log)
            card.addRow(SettingsRowView(
                title: L("数据目录"),
                trailing: [button(L("在访达中显示"), #selector(revealDirectory))]
            ))
        }
    }

    func refresh(_ pane: SettingsPane) {
        sizeRequest.invalidate()
        if pane != .keyboard { recorder.cancelRecording() }
        switch pane {
        case .general:
            language.selectItem(withTitle: settings.language.title)
            appearance.selectItem(withTitle: settings.appearance.title)
            background.refresh()
            appearanceCard?.updateDividers()
            let status = SystemAccess.loginStatus
            login.state = status == .enabled || status == .requiresApproval ? .on : .off
            loginApprovalRow?.isHidden = status != .requiresApproval
            generalCard?.updateDividers()
            paste.state = settings.directPaste ? .on : .off
            grantPaste.isHidden = SystemAccess.accessibilityGranted
            plainText.state = settings.plainTextByDefault ? .on : .off
        case .keyboard:
            let keyboard = settings.keyboard
            recorder.shortcut = keyboard.open
            confirmation.selectItem(withTitle: keyboard.confirm.title)
            numbers.selectItem(at: HistoryShortcut.allCases.firstIndex(of: keyboard.number)!)
        case .history:
            limit.selectItem(at: AppSettings.historyLimits.firstIndex(of: settings.historyLimit)!)
            pause.state = settings.paused ? .on : .off
            imageOCR.state = settings.imageOCR ? .on : .off
            refreshOCRStatus()
            excludedApps.refresh()
            refreshDatabaseSize()
        case .permissions: refreshPermissions()
        case .about:
            let hasLog = FileManager.default.fileExists(atPath: paths.errorLog.path)
            openLogButton.isEnabled = hasLog
            logRow?.setSubtitle(hasLog
                ? L("仅记录时间、操作名与错误代码，不记录剪贴板内容。")
                : L("目前没有错误日志。"))
        }
    }

    func refreshOCRStatus() {
        guard let ocrFooter else { return }
        let progress = actions.ocrProgress()
        if progress.total == 0 {
            ocrFooter.stringValue = L("在本地识别图片中的文字以便搜索，结果加密保存在历史数据库中。")
        } else if progress.indexed >= progress.total {
            ocrFooter.stringValue = L("已为全部 %ld 张图片建立文字索引，可在搜索框直接输入图中文字查找。", progress.total)
        } else {
            ocrFooter.stringValue = L("已为 %ld / %ld 张图片建立文字索引，识别结果加密保存在历史数据库中。", progress.indexed, progress.total)
        }
    }

    private func refreshDatabaseSize() {
        let ticket = sizeRequest.begin()
        let url = paths.historyDatabase
        let locale = L10n.locale
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = Result { () -> Int in
                guard let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
                    throw AppError(L("无法读取历史数据库大小。"), code: .database)
                }
                return size
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.sizeRequest.isCurrent(ticket), self.sizeText.window?.isVisible == true,
                      L10n.locale == locale else { return }
                switch result {
                case .success(let size):
                    self.sizeText.stringValue = ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
                case .failure(let error):
                    self.sizeText.stringValue = "—"
                    self.actions.report(L("数据库占用大小"), error)
                }
            }
        }
    }

    private func refreshPermissions() {
        let clipboard = SystemAccess.clipboardStatus()
        switch clipboard {
        case .allowed: clipboardState.show(L("始终允许"), .systemGreen)
        case .denied: clipboardState.show(L("始终拒绝"), .systemRed)
        case .ask: clipboardState.show(L("每次询问"), .systemOrange)
        case .systemDefault: clipboardState.show(L("系统默认"), .secondaryLabelColor)
        case .notRequired: clipboardState.show(L("无需授权"), .systemGreen)
        case .unknown: clipboardState.show(L("未知"), .secondaryLabelColor)
        }
        let subtitle = clipboard == .ask
            ? L("用于记录复制的内容。") + "\n" + L("为方便自动记录，可在系统设置中选择“始终允许”。")
            : L("用于记录复制的内容。")
        clipboardRow?.setSubtitle(subtitle)
        let trusted = SystemAccess.accessibilityGranted
        accessibilityState.show(trusted ? L("已授权") : L("未授权"), trusted ? .systemGreen : .systemOrange)
        switch SystemAccess.loginStatus {
        case .enabled: loginState.show(L("已启用"), .systemGreen)
        case .notRegistered: loginState.show(L("未启用"), .secondaryLabelColor)
        case .requiresApproval: loginState.show(L("需要批准"), .systemOrange)
        case .notFound: loginState.show(L("找不到应用"), .systemRed)
        @unknown default: loginState.show(L("未知"), .secondaryLabelColor)
        }
    }

    @objc private func changeLanguage() {
        let index = language.indexOfSelectedItem
        guard AppLanguage.allCases.indices.contains(index) else { return }
        settings.language = AppLanguage.allCases[index]
    }

    @objc private func changeAppearance() {
        let index = appearance.indexOfSelectedItem
        guard PanelAppearance.allCases.indices.contains(index) else { return }
        settings.appearance = PanelAppearance.allCases[index]
    }

    @objc private func changeLogin() {
        do { try SystemAccess.setLoginEnabled(login.state == .on) }
        catch { actions.report(L("无法更改登录项"), error) }
        refresh(.general)
    }

    @objc private func openLogin() { SystemAccess.openLoginSettings() }
    @objc private func changePaste() { settings.directPaste = paste.state == .on }
    @objc private func changePlainText() { settings.plainTextByDefault = plainText.state == .on }
    @objc private func changePause() { settings.paused = pause.state == .on }
    @objc private func changeImageOCR() { settings.imageOCR = imageOCR.state == .on }
    @objc private func clearHistory() { actions.clearHistory() }

    @objc private func changeLimit() {
        let selected = limit.indexOfSelectedItem
        guard AppSettings.historyLimits.indices.contains(selected) else { return }
        limit.isEnabled = false
        settings.setHistoryLimit(AppSettings.historyLimits[selected]) { [weak self] outcome in
            guard let self else { return }
            self.limit.isEnabled = true
            self.limit.selectItem(at: AppSettings.historyLimits.firstIndex(of: self.settings.historyLimit)!)
            if case .failure(let error) = outcome { self.actions.report(L("无法调整保留条数"), error) }
        }
    }

    @objc private func openClipboard() {
        do { try SystemAccess.openClipboardSettings() }
        catch { actions.report(L("无法打开系统设置"), error) }
    }

    @objc private func openAccessibility() {
        do { try SystemAccess.requestAccessibility() }
        catch { actions.report(L("无法打开系统设置"), error) }
    }

    @objc private func saveKeyboard() {
        var keyboard = settings.keyboard
        keyboard.confirm = ConfirmationKey.allCases[confirmation.indexOfSelectedItem]
        keyboard.number = HistoryShortcut.allCases[numbers.indexOfSelectedItem]
        applyKeyboard(keyboard)
    }

    @objc private func resetKeyboard() { applyKeyboard(KeyboardSettings()) }

    private func applyKeyboard(_ keyboard: KeyboardSettings) {
        do {
            try settings.setKeyboard(keyboard)
        } catch {
            refresh(.keyboard)
            actions.report(L("注册快捷键"), error)
        }
    }

    @objc private func revealDirectory() { NSWorkspace.shared.activateFileViewerSelecting([paths.directory]) }

    @objc private func openLog() {
        let url = paths.errorLog
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        if !NSWorkspace.shared.open(url) { actions.report(L("打开错误日志"), AppError(L("无法打开错误日志"))) }
    }
}
