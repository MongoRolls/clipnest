import AppKit

/// 面板的生命周期、列表刷新与状态；表格/右键菜单在 `+Table.swift`，按键与记录操作在 `+Actions.swift`。
/// 扩展文件需要读写的成员保持 internal，只在本文件修改的成员使用 private(set)。
@MainActor
final class HistoryPanelController: NSObject, NSWindowDelegate {
    let service: HistoryService
    let settings: AppSettings
    private(set) lazy var actions = PanelActions(service: service)
    private(set) lazy var onActionFailure: (Error) -> Void = { [weak self] in
        self?.showNotice($0.localizedDescription, isError: true)
    }
    var onShowSettings: (() -> Void)?
    var onOpenErrorLog: (() -> Void)?
    var onError: ((String, Error) -> Void)?
    var directPaste: Bool { settings.directPaste }

    private(set) var keyboard: KeyboardSettings
    private(set) lazy var view = HistoryPanelView(
        listButton: FooterButton(title: PanelShortcut.lists.menuTitle, shortcut: PanelShortcut.lists.hint, target: self, action: #selector(switchList)),
        clearButton: FooterButton(title: PanelShortcut.clear.menuTitle, shortcut: PanelShortcut.clear.hint, target: self, action: #selector(clearHistory)))
    var window: HistoryWindow { view.window }
    var table: HistoryTableView { view.table }
    var search: NSSearchField { view.search }

    var showingFavorites = false
    struct RestorationState {
        let wasVisible: Bool
        let favorites: Bool
        let query: String
        let selection: PanelRowID?
        let accessibilityHintNeeded: Bool
    }
    private var stateForNextOpen: RestorationState?
    var selectionToRestore: PanelRowID?
    var accessibilityHintNeeded = false
    var restorationState: RestorationState {
        stateForNextOpen ?? RestorationState(wasVisible: window.isVisible && NSApp.isActive, favorites: showingFavorites,
                                            query: search.stringValue, selection: selectionToRestore ?? content.id(at: table.selectedRow),
                                            accessibilityHintNeeded: accessibilityHintNeeded)
    }

    func restore(_ state: RestorationState) {
        stateForNextOpen = state
        if state.wasVisible { showWindow(nil) }
    }

    /// 删除后可撤销的记录。用户随后编辑过搜索词时，⌘Z 不再触发恢复记录。
    struct UndoState {
        var deleted: HistoryStore.DeletedEntry?
        var searchEdited = false
        var canUndo: Bool { deleted != nil && !searchEdited }
    }
    /// 临时提示与自动消失的票据放在一起，新提示或清除都使旧的定时回调失效。
    private struct NoticeState {
        var request = RequestGuard()
        var current: (message: String, isError: Bool)?
    }

    private(set) var content = PanelContent.entries([], highlights: [:])
    var appliedQuery = ""
    var ocrSnippetCache: [String: EntryPresentation.OCRSnippet?] = [:]
    var rowCount: Int { content.count }
    let historySearch = HistorySearch()
    private var resetSelectionOnResults = false
    let keyRouter = PanelKeyRouter()
    private(set) var presentation = RequestGuard()
    private(set) var applyingResults = false
    var followingPreview = false
    var undo = UndoState()
    private var notice = NoticeState()
    var imageTextRequest = RequestGuard()
    var imageTextAction: (id: String, message: String)? {
        didSet {
            if imageTextAction == nil { imageTextRequest.invalidate() }
            updateOperation()
        }
    }
    private(set) lazy var frames = PanelFrameController(window: window)
    static let favoriteDragType = NSPasteboard.PasteboardType("com.clipnest.favorite-id")
    private(set) lazy var previewCoordinator = HistoryPreviewCoordinator(service: service)
    var plainTextMenuItem: NSMenuItem!
    var imageTextMenuItem: NSMenuItem!
    var favoriteMenuItem: NSMenuItem!
    var deleteMenuItem: NSMenuItem!
    var ignoreAppSeparator: NSMenuItem!
    var ignoreAppMenuItem: NSMenuItem!
    private(set) var previousApp: NSRunningApplication?
    private lazy var entryMenu = makeContextMenu()

    init(service: HistoryService, settings: AppSettings) {
        self.service = service
        self.settings = settings
        self.keyboard = settings.keyboard
        super.init()
        window.applyAppearance(settings.appearance)
        window.delegate = self
        NotificationCenter.default.addObserver(self, selector: #selector(applicationResignedActive),
            name: NSApplication.didResignActiveNotification, object: NSApp)
        window.keyAction = { [weak self] event in self?.handleKey(event) ?? false }
        actions.onFailure = onActionFailure
        for (button, action) in [(view.settingsButton, #selector(openSettings)),
                                 (view.resumeButton, #selector(resumeRecording)),
                                 (view.grantAccessibilityButton, #selector(openAccessibilitySettings)),
                                 (view.retryButton, #selector(retryLoad)),
                                 (view.logButton, #selector(openErrorLog)),
                                 (view.archiveButton, #selector(confirmArchive))] {
            button.target = self
            button.action = action
        }
        search.delegate = self
        table.delegate = self
        table.dataSource = self
        table.registerForDraggedTypes([Self.favoriteDragType])
        table.target = self
        table.action = #selector(copyClickedRow)
        // 菜单收起时指针可能落在另一行，查看预览期间保持用户选中的记录。
        table.allowsHoverSelection = { [weak self] in self?.previewCoordinator.hasPreview == false }
        table.rowIDAtRow = { [weak self] row in
            guard let self, !self.historySearch.isPending else { return nil }
            return self.content.id(at: row)
        }
        table.menu = entryMenu
        previewCoordinator.onError = { [weak self] action, error in
            self?.onError?(action, error)
            self?.showNotice(error.localizedDescription, isError: true)
        }
        previewCoordinator.onCopiedText = { [weak self] in
            self?.showNotice(L("已复制图中文字"))
        }
        updateKeyboard(keyboard)
        updatePausedState()
        updateAccessibilityBanner()
        updateControls()
        service.observeChanges(owner: self) { [weak self] change in self?.serviceDidChange(change) }
    }

    /// 当前列表的完整内容，搜索结果从中过滤。
    var currentList: [Entry] { showingFavorites ? service.favorites : service.entries }

    func updateAppearance() {
        window.applyAppearance(settings.appearance)
    }

    func refreshCommands() {
        if window.isVisible, content.commands != nil { refresh() }
    }

    private func setBanner(_ banner: NSView, hidden: Bool) {
        guard banner.isHidden != hidden else { return }
        banner.isHidden = hidden
        updateMinimumHeight()
        if window.isVisible { resizeToFitHistory() }
    }

    func updatePausedState() {
        setBanner(view.pausedBanner, hidden: !settings.paused)
    }

    func updateAccessibilityBanner() {
        if !settings.directPaste || actions.isAccessibilityGranted() {
            accessibilityHintNeeded = false
        }
        setBanner(view.accessibilityBanner, hidden: !accessibilityHintNeeded)
    }

    private func serviceDidChange(_ change: HistoryService.Change) {
        switch change {
        case .state:
            if service.busy {
                imageTextAction = nil
                previewCoordinator.closeIfLoading()
            }
            previewCoordinator.updateAvailability()
            updateControls()
        case .all:
            if window.isVisible { refresh() }
        case .history:
            if window.isVisible {
                if showingFavorites { updateControls() } else { refresh() }
            }
        }
    }

    func updateBackground(_ image: NSImage?, intensity: Int) {
        view.surface.setBackground(image, intensity: intensity)
    }

    func updateKeyboard(_ settings: KeyboardSettings) {
        keyboard = settings
        keyRouter.cancelPending()
        for item in [plainTextMenuItem!, imageTextMenuItem!] {
            item.keyEquivalent = keyboard.confirm.keyEquivalent
            item.keyEquivalentModifierMask = keyboard.confirm.flags.union(.shift)
        }
        table.reloadData()
    }

    func cancelPendingActions(cancelSearch: Bool = true) {
        presentation.invalidate()
        discardUndo()
        clearNotice()
        imageTextAction = nil
        if cancelSearch { historySearch.cancel() }
        keyRouter.cancelPending()
        closePreview()
        if let sheet = window.attachedSheet { window.endSheet(sheet, returnCode: .cancel) }
    }

    func hide() {
        frames.endPresentation()
        cancelPendingActions()
        window.orderOut(nil)
    }

    @objc private func applicationResignedActive() {
        // 失活时主动 orderOut，避免面板滞留在旧位置并在下次激活时闪现；已隐藏时保留直接粘贴票据。
        if window.isVisible && NSApp.modalWindow == nil { hide() }
        else { frames.endPresentation() }
    }

    @objc func showWindow(_ sender: Any?) {
        let opening = frames.needsPosition
        if opening && window.isVisible { window.orderOut(nil) }
        service.observeClipboardSource()
        cancelPendingActions(cancelSearch: false)
        updatePausedState()
        updateAccessibilityBanner()
        if let app = NSWorkspace.shared.frontmostApplication, app.processIdentifier != getpid() { previousApp = app }
        else if opening { previousApp = nil }
        if opening {
            let cursor = NSEvent.mouseLocation
            frames.endPresentation()
            let restored = stateForNextOpen
            stateForNextOpen = nil
            showingFavorites = restored?.favorites ?? false
            selectionToRestore = restored?.selection
            if let restored {
                accessibilityHintNeeded = restored.accessibilityHintNeeded
                updateAccessibilityBanner()
            }
            search.stringValue = restored?.query ?? ""
            refresh(resetSelection: true)
            frames.begin(at: cursor, height: preferredHeight)
        }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(search)
        search.selectText(nil)
    }
    func windowWillMove(_ notification: Notification) {
        frames.willMove()
    }
    @objc func openSettings() {
        guard service.isIdle else { return }
        onShowSettings?()
    }
    @objc private func resumeRecording() {
        settings.paused = false
    }
    @objc private func openAccessibilitySettings() {
        hide()
        do { try SystemAccess.requestAccessibility() }
        catch { onError?(L("无法打开系统设置"), error) }
    }
    @objc private func retryLoad() { service.retryLoad() }
    @objc private func openErrorLog() { onOpenErrorLog?() }
    @objc private func confirmArchive() {
        guard service.canArchiveAfterFailure, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = L("归档旧数据库并重新开始？")
        alert.informativeText = L("原数据库将保留在归档文件中。重新开始后，历史记录和收藏将显示为空。")
        alert.addButton(withTitle: L("取消"))
        alert.addButton(withTitle: L("归档并重新开始"))
        let ticket = presentation.ticket
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertSecondButtonReturn, let self, self.presentation.isCurrent(ticket) else { return }
            self.service.archiveAndRestart()
        }
    }
    func windowShouldClose(_ sender: NSWindow) -> Bool { hide(); return false }
    func windowDidResignKey(_ notification: Notification) {
        keyRouter.cancelPending()
        imageTextAction = nil
        previewCoordinator.closeIfLoading()
    }
    var selected: Entry? { content.entries.indices.contains(table.selectedRow) ? content.entries[table.selectedRow] : nil }
    func refresh(resetSelection: Bool = false) {
        if resetSelection {
            imageTextAction = nil
            closePreview()
            keyRouter.cancelPending()
            resetSelectionOnResults = true
        }
        let query = search.stringValue
        historySearch.filter(currentList, query: query) { [weak self] result in
            self?.applyResults(result, for: query)
        }
        table.isEnabled = service.isIdle && !historySearch.isPending
        if historySearch.isPending && rowCount == 0 { view.emptyText.stringValue = L("正在搜索…") }
    }
    private func applyResults(_ result: HistorySearch.Result, for query: String) {
        appliedQuery = query
        ocrSnippetCache.removeAll(keepingCapacity: true)
        let reset = resetSelectionOnResults
        resetSelectionOnResults = false
        let selectedID = selectionToRestore ?? (reset ? nil : content.id(at: table.selectedRow))
        selectionToRestore = nil
        let oldIndex = reset ? 0 : table.selectedRow
        let anchor = reset ? nil : table.scrollAnchor()
        switch result {
        case let .entries(entries, ranges):
            content = .entries(entries, highlights: ranges)
        case let .commands(query):
            content = .commands(PanelCommand.matching(query, paused: settings.paused, directPaste: directPaste,
                                                       plainText: settings.plainTextByDefault, imageOCR: settings.imageOCR))
        case .invalidRegex:
            content = .message(L("正则表达式无效，请检查表达式和标志。"))
        case .regexTimedOut:
            content = .message(L("正则匹配时间过长，请缩小匹配范围。"))
        }
        // 刷新表格期间 AppKit 可能短暂清除选择，以最终选中项判断预览和识别是否仍有效。
        applyingResults = true
        table.menu = content.commands == nil ? entryMenu : nil
        table.reloadData()
        if rowCount > 0 {
            let rows = 0..<rowCount
            let index = selectedID.flatMap { id in rows.first { content.id(at: $0) == id } } ?? max(0, min(oldIndex, rowCount - 1))
            table.select(row: index)
            if reset || selectedID != content.id(at: index) {
                table.scrollRowToVisible(index)
            } else if let anchor, let row = rows.first(where: { content.id(at: $0) == anchor.id }) {
                table.scroll(NSPoint(x: table.visibleRect.minX, y: table.rect(ofRow: row).minY + anchor.offset))
            }
        }
        applyingResults = false
        checkSelectedEntry()
        if content.commands != nil { table.setAccessibilityValue(L("%ld 个命令", rowCount)) }
        else { table.setAccessibilityValue(showingFavorites ? L("%ld 条收藏记录", rowCount) : L("%ld 条历史记录", rowCount)) }
        updateControls()
        resizeToFitHistory()
        let ticket = presentation.ticket
        keyRouter.deliverPending(while: { presentation.isCurrent(ticket) && window.isKeyWindow && service.isIdle },
                                 perform: performKey)
    }

    // MARK: - 控件状态、提示与高度

    private var preferredHeight: CGFloat {
        frames.height(for: content, extraHeight: extraChromeHeight, failed: service.loadFailure != nil)
    }
    private func resizeToFitHistory() { frames.resize(to: preferredHeight) }
    private func updateControls() {
        table.isEnabled = service.isIdle && !historySearch.isPending
        updateOperation()
        view.emptyText.isHidden = rowCount > 0
        view.emptyText.stringValue = content.emptyMessage ?? (!service.ready ? (service.busy ? L("正在加载历史…") : "") :
            (currentList.isEmpty ?
                (showingFavorites ? L("右键历史记录或按 ⌘D 即可收藏，常用内容会显示在这里。") : L("还没有复制记录。复制文字、图片或文件后会显示在这里。")) : L("没有匹配的记录。")))
        search.placeholderString = showingFavorites ? L("搜索收藏…") : L("搜索…")
        search.setAccessibilityLabel(showingFavorites ? L("搜索收藏记录") : L("搜索剪贴板历史"))
        table.setAccessibilityLabel(content.commands != nil ? L("面板命令") : (showingFavorites ? L("收藏记录") : L("剪贴板历史记录")))
        view.listButton.title = showingFavorites ? L("返回历史") : L("查看收藏")
        view.listButton.isEnabled = service.isIdle
        view.clearButton.isEnabled = service.isIdle && !service.entries.isEmpty
        view.settingsButton.isEnabled = service.isIdle
        view.showFailure(service.loadFailure, canRetry: !service.busy && !service.quitting, canArchive: service.canArchiveAfterFailure)
    }
    private var extraChromeHeight: CGFloat {
        (view.pausedBanner.isHidden ? 0 : 28)
            + (view.accessibilityBanner.isHidden ? 0 : 28)
            + (view.operation.isHidden ? 0 : ceil(view.operation.intrinsicContentSize.height) + 4)
    }
    private func updateMinimumHeight() {
        let minimumHeight = HistoryLayout.minimumHeight + extraChromeHeight
        if window.minSize.height != minimumHeight { window.minSize.height = minimumHeight }
    }
    func clearNotice() {
        notice.request.invalidate()
        notice.current = nil
    }
    func showNotice(_ message: String, isError: Bool = false, duration: TimeInterval? = 2.5) {
        guard window.isVisible, !message.isEmpty else { return }
        notice.request.invalidate()
        notice.current = (message, isError)
        updateOperation()
        guard let duration else { return }
        let token = notice.request.begin()
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.notice.request.isCurrent(token) else { return }
            self.notice.current = nil
            self.updateOperation()
        }
    }
    private func updateOperation() {
        let message: String
        let isError: Bool
        if service.busy {
            message = L("正在处理…")
            isError = false
        } else if let action = imageTextAction, !action.message.isEmpty {
            message = action.message
            isError = false
        } else if let current = notice.current {
            message = current.message
            isError = current.isError
        } else {
            message = ""
            isError = false
        }
        view.operation.textColor = isError ? .systemRed : .secondaryLabelColor
        view.operation.stringValue = message
        let changed = view.operation.isHidden != message.isEmpty
        view.operation.isHidden = message.isEmpty
        updateMinimumHeight()
        if changed && window.isVisible { resizeToFitHistory() }
    }
}
