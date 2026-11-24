import AppKit

/// 表格的数据源、代理与右键菜单：行视图、行高、收藏拖动排序、选中项校验及菜单显隐。
extension HistoryPanelController: NSTableViewDataSource, NSTableViewDelegate, NSMenuItemValidation, NSMenuDelegate {
    /// 作用于当前选中记录的操作，右键菜单和快捷键共用同一可用条件。
    private static let selectionActions: Set<Selector> = [#selector(copySelection), #selector(copySelectionAlternateFormat),
        #selector(extractImageText), #selector(deleteSelection), #selector(showPreview), #selector(toggleFavorite), #selector(ignoreSourceApp)]

    func numberOfRows(in tableView: NSTableView) -> Int { rowCount }
    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if let commands = content.commands {
            let command = commands[row]
            let cell = tableView.makeView(withIdentifier: PanelCommandCell.reuseIdentifier, owner: self) as? PanelCommandCell
                ?? PanelCommandCell(frame: .zero)
            cell.configure(command: command,
                           title: command.title(paused: settings.paused, directPaste: directPaste,
                                                plainText: settings.plainTextByDefault, imageOCR: settings.imageOCR),
                           shortcut: keyboard.number.label(for: row))
            return cell
        }
        let entry = content.entries[row]
        let cell = tableView.makeView(withIdentifier: HistoryCell.reuseIdentifier, owner: self) as? HistoryCell ?? HistoryCell(frame: .zero)
        let ocrSnippet: EntryPresentation.OCRSnippet?
        if case .image = entry.content, let ocrText = entry.ocrText, !ocrText.isEmpty, !appliedQuery.isEmpty {
            if let cached = ocrSnippetCache[entry.id] {
                ocrSnippet = cached
            } else {
                let computed = EntryPresentation.ocrSnippet(in: ocrText, query: appliedQuery)
                ocrSnippetCache[entry.id] = computed
                ocrSnippet = computed
            }
        } else {
            ocrSnippet = nil
        }
        cell.configure(entry: entry, row: row, isFavorite: service.favoriteIDs.contains(entry.id),
                       inFavoritesList: showingFavorites, numberShortcut: keyboard.number,
                       highlightRanges: content.highlights(for: entry.id), ocrSnippet: ocrSnippet)
        return cell
    }
    func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat {
        content.rowHeight(at: row)
    }
    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        let identifier = HistoryRowView.reuseIdentifier
        if let view = tableView.makeView(withIdentifier: identifier, owner: self) as? HistoryRowView { return view }
        let view = HistoryRowView()
        view.identifier = identifier
        return view
    }
    private var canReorderFavorites: Bool {
        showingFavorites && content.commands == nil && service.isIdle && !historySearch.isPending
    }
    func tableView(_ tableView: NSTableView, pasteboardWriterForRow row: Int) -> NSPasteboardWriting? {
        guard canReorderFavorites, content.entries.indices.contains(row) else { return nil }
        let item = NSPasteboardItem()
        guard item.setString(content.entries[row].id, forType: Self.favoriteDragType) else { return nil }
        return item
    }
    func tableView(_ tableView: NSTableView, draggingSession session: NSDraggingSession,
                   willBeginAt screenPoint: NSPoint, forRowIndexes rowIndexes: IndexSet) {
        table.draggedSinceMouseDown = true
    }
    func tableView(_ tableView: NSTableView, validateDrop info: NSDraggingInfo,
                   proposedRow row: Int, proposedDropOperation operation: NSTableView.DropOperation) -> NSDragOperation {
        guard canReorderFavorites, (info.draggingSource as? NSTableView) === tableView,
              (0...content.entries.count).contains(row) else { return [] }
        tableView.setDropRow(row, dropOperation: .above)
        return .move
    }
    func tableView(_ tableView: NSTableView, acceptDrop info: NSDraggingInfo,
                   row: Int, dropOperation: NSTableView.DropOperation) -> Bool {
        guard canReorderFavorites, (info.draggingSource as? NSTableView) === tableView,
              dropOperation == .above, (0...content.entries.count).contains(row),
              let id = info.draggingPasteboard.string(forType: Self.favoriteDragType),
              let source = content.entries.firstIndex(where: { $0.id == id }) else { return false }
        if row == source || row == source + 1 { return true }
        // 搜索结果可能只包含部分收藏，以可见的相邻记录确定它在完整列表中的位置。
        let atEnd = row == content.entries.count
        let neighbor = content.entries[atEnd ? row - 1 : row].id
        service.moveFavorite(id, relativeTo: neighbor, insertAfter: atEnd, onFailure: onActionFailure)
        return true
    }
    func tableViewSelectionDidChange(_ notification: Notification) {
        if !applyingResults { checkSelectedEntry() }
    }
    func checkSelectedEntry() {
        if !followingPreview { previewCoordinator.closeIfMismatch(selectedID: selected?.id) }
        if let action = imageTextAction, selected?.id != action.id { imageTextAction = nil }
    }

    // MARK: - 右键菜单

    func makeContextMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        func add(_ title: String, _ action: Selector) -> NSMenuItem {
            let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
            item.target = self
            return item
        }
        _ = add(L("复制"), #selector(copySelection))
        // 纯文本/原格式切换按键随“确认复制键”变化，由 updateKeyboard 设置。
        plainTextMenuItem = add(L("复制为纯文本"), #selector(copySelectionAlternateFormat))
        imageTextMenuItem = add(L("提取图中文字"), #selector(extractImageText))
        PanelShortcut.preview.apply(to: add(PanelShortcut.preview.menuTitle, #selector(showPreview)))
        favoriteMenuItem = add(PanelShortcut.favorite.menuTitle, #selector(toggleFavorite))
        PanelShortcut.favorite.apply(to: favoriteMenuItem)
        deleteMenuItem = add(PanelShortcut.delete.menuTitle, #selector(deleteSelection))
        PanelShortcut.delete.apply(to: deleteMenuItem)
        ignoreAppSeparator = .separator()
        menu.addItem(ignoreAppSeparator)
        ignoreAppMenuItem = add("", #selector(ignoreSourceApp))
        return menu
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        if let action = menuItem.action, Self.selectionActions.contains(action) {
            return service.isIdle && !historySearch.isPending && selected != nil
        }
        return true
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === table.menu else { return }
        if case .text? = selected?.content {
            plainTextMenuItem.title = settings.plainTextByDefault ? L("保留格式复制") : L("复制为纯文本")
            plainTextMenuItem.isHidden = false
        } else {
            plainTextMenuItem.isHidden = true
        }
        if case .image? = selected?.content { imageTextMenuItem.isHidden = false }
        else { imageTextMenuItem.isHidden = true }
        favoriteMenuItem.title = selected.map { service.favoriteIDs.contains($0.id) } == true ? L("取消收藏") : L("收藏")
        deleteMenuItem.isHidden = showingFavorites
        if let bundleID = selected?.sourceAppBundleID, !settings.ignoredBundleIDs.contains(bundleID) {
            ignoreAppMenuItem.title = L("忽略来自「%@」的记录", AppMetadataCache.shared.displayName(for: bundleID))
            ignoreAppMenuItem.isHidden = false
            ignoreAppSeparator.isHidden = false
        } else {
            ignoreAppMenuItem.isHidden = true
            ignoreAppSeparator.isHidden = true
        }
    }
}
