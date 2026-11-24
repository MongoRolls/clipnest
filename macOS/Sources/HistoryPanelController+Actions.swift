import AppKit

/// 面板按键分派、搜索框变化响应及记录和列表操作：复制与直接粘贴、执行命令、提取图中文字、预览、收藏、忽略来源、删除与撤销、清空。
extension HistoryPanelController: NSSearchFieldDelegate {
    func handleKey(_ event: NSEvent) -> Bool {
        let searchText = search.currentEditor()?.string ?? search.stringValue
        let state = PanelKeyState(commands: content.commands != nil, searching: historySearch.isPending,
                                  searchEmpty: searchText.isEmpty, previewOpen: previewCoordinator.hasPreview,
                                  hasEntries: !content.entries.isEmpty, canUndoDelete: undo.canUndo)
        return keyRouter.route(event, keyboard: keyboard, state: state, perform: performKey)
    }

    func performKey(_ action: PanelKeyRouter.Action) {
        switch action {
        case .numbered(let index):
            guard index < rowCount else { return }
            table.select(row: index)
            activate(row: index)
        case .step(let offset):
            guard rowCount > 0 else { return }
            let next = max(0, min(rowCount - 1, table.selectedRow + offset))
            let follow = previewCoordinator.hasPreview && content.commands == nil
            followingPreview = follow
            table.select(row: next)
            followingPreview = false
            table.scrollRowToVisible(next)
            if follow { showPreview() }
        case .confirm: copySelection()
        case .confirmText: copySelectionText()
        case .togglePreview: togglePreview()
        case .undoDelete: undoDelete()
        case .runCommand: activate(row: table.selectedRow)
        case .shortcut(let shortcut):
            switch shortcut {
            case .search: window.makeFirstResponder(search); search.selectText(nil)
            case .preview: showPreview()
            case .favorite: toggleFavorite()
            case .lists: switchList()
            case .delete: deleteSelection()
            case .clear: clearHistory()
            case .close:
                keyRouter.cancelPending()
                if previewCoordinator.hasPreview { closePreview() } else { hide() }
            case .settings, .quit: break
            }
        }
    }

    func controlTextDidChange(_ obj: Notification) {
        undo.searchEdited = true
        selectionToRestore = nil
        refresh(resetSelection: true)
    }

    @objc func copySelection() { copy(row: table.selectedRow) }
    @objc func copySelectionAlternateFormat() {
        copy(row: table.selectedRow, asPlainText: !settings.plainTextByDefault)
    }
    func copySelectionText() {
        if case .image? = selected?.content { extractImageText() }
        else { copySelectionAlternateFormat() }
    }
    @objc func extractImageText() {
        guard service.isIdle, !historySearch.isPending, let entry = selected, case .image = entry.content else { return }
        let ticket = presentation.ticket
        let token = imageTextRequest.begin()
        imageTextAction = (entry.id, entry.ocrText == nil ? L("正在提取图中文字…") : "")
        service.recognizeImageText(for: entry.id) { [weak self] result in
            guard let self, self.imageTextRequest.isCurrent(token), self.presentation.isCurrent(ticket),
                  self.window.isVisible, NSApp.isActive, self.service.isIdle, self.selected?.id == entry.id else { return }
            switch result {
            case .success(let text) where text.isEmpty:
                self.imageTextAction = (entry.id, L("图中未识别到文字。"))
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                    if self?.imageTextRequest.isCurrent(token) == true { self?.imageTextAction = nil }
                }
            case .success(let text):
                self.imageTextAction = nil
                self.copy(entry, payload: .text(text), promote: false)
            case .failure(let error):
                self.imageTextAction = nil
                if !(error is CancellationError) {
                    self.onError?(L("提取图中文字"), error)
                    self.showNotice(error.localizedDescription, isError: true)
                }
            }
        }
    }
    @objc func copyClickedRow() {
        guard table.clickMatchesEntry else { return }
        activate(row: table.clickedRow)
    }

    func activate(row: Int) {
        guard service.isIdle, !historySearch.isPending else { return }
        guard let commands = content.commands else { copy(row: row); return }
        guard commands.indices.contains(row) else { return }
        switch commands[row] {
        case .pause: settings.paused.toggle()
        case .clear: clearHistory()
        case .settings: openSettings()
        case .favorites: showList(favorites: true)
        case .history: showList(favorites: false)
        case .system: settings.appearance = .system
        case .dark: settings.appearance = .dark
        case .light: settings.appearance = .light
        case .paste: settings.directPaste.toggle()
        case .plainText: settings.plainTextByDefault.toggle()
        case .imageOCR: settings.imageOCR.toggle()
        case .quit: NSApp.terminate(nil)
        }
    }
    private func copy(row: Int, asPlainText: Bool? = nil) {
        guard !historySearch.isPending, content.entries.indices.contains(row) else { return }
        let entry = content.entries[row]
        let usePlainText = asPlainText ?? settings.plainTextByDefault
        let plainText: Payload?
        if usePlainText, case let .text(text) = entry.content {
            plainText = .text(text)
        } else {
            plainText = nil
        }
        copy(entry, payload: plainText)
    }
    private func copy(_ entry: Entry, payload replacement: Payload?, promote: Bool = true) {
        let ticket = presentation.ticket
        let target = previousApp
        service.copyEntry(entry, replacement: replacement, promote: promote, onFailure: onActionFailure) { [weak self] version in
            guard let self, self.presentation.isCurrent(ticket), self.window.isVisible, NSApp.isActive else { return }
            self.hide()
            let pasteTicket = self.presentation.ticket
            self.actions.returnToTarget(target, version: version, directPaste: self.directPaste, isCurrent: { [weak self] in
                guard let self else { return false }
                return self.presentation.isCurrent(pasteTicket) && !self.window.isVisible && self.directPaste && !self.service.quitting
            }, onNeedsAccessibility: { [weak self] in
                guard let self else { return }
                self.accessibilityHintNeeded = true
                self.actions.promptAccessibilityOnce()
            }, report: { [weak self] in self?.onError?(L("直接粘贴"), $0) })
        }
    }
    @objc func showPreview() { presentPreview(toggle: false) }
    func togglePreview() { presentPreview(toggle: true) }
    private func presentPreview(toggle: Bool) {
        guard service.isIdle, !historySearch.isPending, content.commands == nil, let entry = selected else { return }
        previewCoordinator.show(entry: entry, in: table, toggle: toggle) { [weak self] in
            guard let self else { return false }
            return self.selected?.id == entry.id && self.window.isVisible && NSApp.isActive
                && !self.service.quitting
        }
    }
    func closePreview() {
        previewCoordinator.close()
    }
    @objc func switchList() {
        showList(favorites: !showingFavorites)
    }
    private func showList(favorites: Bool) {
        guard service.isIdle else { return }
        discardUndo()
        clearNotice()
        selectionToRestore = nil
        showingFavorites = favorites
        search.stringValue = ""
        refresh(resetSelection: true)
        window.makeFirstResponder(search)
    }
    @objc func toggleFavorite() {
        guard !historySearch.isPending, let entry = selected else { return }
        service.toggleFavorite(entry.id, onFailure: onActionFailure)
    }
    @objc func ignoreSourceApp() {
        guard !historySearch.isPending, let bundleID = selected?.sourceAppBundleID,
              !settings.ignoredBundleIDs.contains(bundleID) else { return }
        var updated = settings.ignoredBundleIDs
        updated.insert(bundleID)
        settings.ignoredBundleIDs = updated
        showNotice(L("已忽略来自「%@」的记录", AppMetadataCache.shared.displayName(for: bundleID)))
    }
    func discardUndo() {
        guard let deleted = undo.deleted else { return }
        undo.deleted = nil
        service.discardDeleted(deleted)
    }
    func undoDelete() {
        guard service.isIdle, !historySearch.isPending, let deleted = undo.deleted else { return }
        undo.deleted = nil
        selectionToRestore = .entry(deleted.id)
        service.restoreDeleted(deleted, onFailure: onActionFailure) { [weak self] restored in
            guard let self else { return }
            if restored { self.showNotice(L("已恢复记录")) }
            else { self.selectionToRestore = nil }
        }
    }
    @objc func deleteSelection() {
        guard service.isIdle, !historySearch.isPending, content.commands == nil, let entry = selected else { return }
        discardUndo()
        let fromFavorites = showingFavorites
        service.deleteForUndo(entry.id, fromFavorites: fromFavorites, onFailure: onActionFailure) { [weak self] deleted in
            guard let self else { return }
            guard self.window.isVisible else {
                self.service.discardDeleted(deleted)
                return
            }
            self.undo.deleted = deleted
            self.undo.searchEdited = false
            self.showNotice(fromFavorites ? L("已取消收藏，按 ⌘Z 撤销") : L("已删除，按 ⌘Z 撤销"), duration: 6)
        }
    }
    @objc func clearHistory() {
        actions.confirmClearHistory(beforeClear: { [weak self] in
            self?.discardUndo()
            self?.clearNotice()
        })
    }
}
