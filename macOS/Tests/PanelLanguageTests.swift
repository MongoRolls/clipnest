import AppKit

extension PanelTests {
    static func checkCommandsAndLanguage(driver: Driver, preferences: AppSettings, board: NSPasteboard,
                                         pasteboard: ClipboardAccess, db: HistoryStore, views: String,
                                         position: String, previousApp: NSRunningApplication?) throws {
        let delegate = driver.delegate, window = driver.window, table = driver.table
        try driver.openForSearch()
        let beforeCommands = board.changeCount
        for paused in [true, false] {
            try driver.query(">pause")
            try wait(for: "暂停或恢复命令") { table.isEnabled && table.numberOfRows == 1 }
            try Tests.expect(table.menu(for: try driver.pointerEvent(.rightMouseDown, row: 0)) == nil,
                             "命令行不提供历史记录右键操作")
            try driver.press(36, "\r")
            try wait(for: "命令更新记录状态") { preferences.paused == paused }
            try driver.openForSearch()
        }
        try Tests.expect(board.changeCount == beforeCommands, "执行命令保留剪贴板")
        try driver.query(">appearance dark")
        try driver.press(18, "1", flags: .control)
        try wait(for: "数字选取命令立即切换深色") { preferences.appearance == .dark && window.appearance?.name == .darkAqua }
        try driver.query(">appearance system")
        try wait(for: "定位跟随系统的命令") { table.numberOfRows == 1 && table.isEnabled }
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            NSApp.postEvent(try driver.pointerEvent(type, row: 0), atStart: false)
        }
        try wait(for: "点击命令切回系统外观") { preferences.appearance == .system && window.appearance == nil }
        try driver.query("/[/")
        try wait(for: "无效正则的空态") { table.isEnabled && table.numberOfRows == 0 }
        try driver.query(#"/^enum\s+PopupPosition:/m"#)
        try driver.press(36, "\r", flags: .command)
        try wait(for: "从正则结果复制完整源码") { board.string(forType: .string) == position && !window.isVisible }

        let path = TestProject.root.appendingPathComponent("macOS/Sources/HistoryPanelController.swift").standardizedFileURL.path
        try ClipboardAccess(board).write(.files([path]))
        try driver.openForSearch()
        let fileID = HistoryStore.fingerprint(.files([path]))
        try driver.query("type:file hpc")
        try wait(for: "模糊匹配驼峰文件名") { table.isEnabled && table.rowIDAtRow?(0) == .entry(fileID) }
        try driver.press(36, "\r", flags: .command)
        try wait(for: "复制模糊匹配的文件") {
            (board.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL])?.first?.path == path &&
                !window.isVisible
        }
        print("PASS 命令暂停与恢复、切换正则和模糊搜索、复制完整源码与文件")
        // 在切换语言前收录实际源码中的空白字符，检查重载后的缓存预览。
        guard let space = views.first(where: \.isWhitespace) else { throw AppError("源码中缺少空白字符。") }
        let blank = Payload.text(String(space))
        let blankID = HistoryStore.fingerprint(blank)
        try ClipboardAccess(board).write(blank)
        try Driver.activate(after: previousApp)
        delegate.showWindow(nil)
        try wait(for: "切换语言前收录空白文本") { table.rowIDAtRow?(0) == .entry(blankID) }
        table.select(row: 0)
        try driver.press(2, "d", flags: .command)
        try wait(for: "收藏写入结束") { table.isEnabled }
        _ = try db.load()
        try Tests.expect(db.favorites.contains { $0.id == blankID }, "空白文本已收藏")
        try driver.press(37, "l", flags: .command)
        try driver.query("type:text")
        try wait(for: "收藏查询显示两条记录") { table.isEnabled && table.numberOfRows == 2 && table.rowIDAtRow?(1) == .entry(blankID) }
        table.select(row: 1)
        let settingsIndex = delegate.statusMenu.indexOfItem(withTitle: "设置…")
        try Tests.expect(settingsIndex >= 0, "存在设置菜单")
        delegate.statusMenu.performActionForItem(at: settingsIndex)
        try wait(for: "设置窗口可用") { NSApp.keyWindow?.title == "ClipNest 设置" }
        guard let original = NSApp.keyWindow,
              let controller = original.windowController as? SettingsWindowController else { throw AppError("无法取得设置窗口。") }
        controller.selectPane(.general)
        guard let generalPage = controller.currentPageView,
              let language = find(NSPopUpButton.self, in: generalPage, matching: { $0.accessibilityLabel() == "界面语言" }) else {
            throw AppError("无法取得语言选择器。")
        }
        language.selectItem(withTitle: "English")
        _ = language.sendAction(language.action, to: language.target)
        try wait(for: "英语设置窗口即时重建") { NSApp.keyWindow?.title == "ClipNest Settings" && NSApp.keyWindow !== original }
        guard let translated = NSApp.keyWindow, let newController = translated.windowController as? SettingsWindowController,
              let page = newController.currentPageView,
              let picker = find(NSPopUpButton.self, in: page, matching: { $0.accessibilityLabel() == "Interface language" }) else {
            throw AppError("未找到重建后的英语设置。")
        }
        try Tests.expect(newController.selectedPane == .general &&
            delegate.statusMenu.indexOfItem(withTitle: "Show History") >= 0 && preferences.language == .english, "保留当前页并切换菜单")
        let show = delegate.statusMenu.indexOfItem(withTitle: "Show History")
        delegate.statusMenu.performActionForItem(at: show)
        let expectedPreview = blank.content.preview
        try Tests.expect(!expectedPreview.contains("空白"), "已加载英语预览格式")
        try wait(for: "英语面板显示重新生成的空白文本预览") {
            guard let current = NSApp.keyWindow as? HistoryWindow, current !== window, let root = current.contentView,
                  let search = find(NSSearchField.self, in: root),
                  search.accessibilityLabel() == L("搜索收藏记录"), search.stringValue == "type:text",
                  let list = find(HistoryTableView.self, in: root), list.selectedRow == 1, list.rowIDAtRow?(1) == .entry(blankID),
                  let cell = list.view(atColumn: 0, row: 1, makeIfNecessary: true) as? HistoryCell else { return false }
            return cell.accessibilityLabel()?.contains(expectedPreview) == true &&
                list.menu?.item(withTitle: L("查看内容")) != nil &&
                find(FooterButton.self, in: root) { $0.title == L("返回历史") } != nil &&
                find(NSButton.self, in: root) { $0.accessibilityLabel() == L("打开设置") } != nil
        }
        let settingsAction = delegate.statusMenu.indexOfItem(withTitle: L("设置…"))
        try Tests.expect(settingsAction >= 0, "存在英语设置入口")
        delegate.statusMenu.performActionForItem(at: settingsAction)
        picker.selectItem(withTitle: "简体中文")
        _ = picker.sendAction(picker.action, to: picker.target)
        try wait(for: "切回中文") { NSApp.keyWindow?.title == "ClipNest 设置" && delegate.statusMenu.indexOfItem(withTitle: "显示历史") >= 0 }
        guard let settings = NSApp.keyWindow, let controls = settings.contentView,
              let directPaste = find(NSSwitch.self, in: controls, matching: { $0.accessibilityLabel() == "直接粘贴到当前应用" }) else {
            throw AppError("未找到直接粘贴设置。")
        }
        try Tests.expect(directPaste.state == .on && preferences.directPaste, "默认开启直接粘贴到当前应用")
        directPaste.performClick(nil)
        try Tests.expect(directPaste.state == .off && !preferences.directPaste, "可在通用设置关闭直接粘贴")
        directPaste.performClick(nil)
        try Tests.expect(preferences.directPaste && NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid(), "开启直接粘贴且当前无外部目标")
        delegate.showWindow(nil)
        guard let history = NSApp.keyWindow as? HistoryWindow, let root = history.contentView,
              let list = find(HistoryTableView.self, in: root) else { throw AppError("未找到新面板。") }
        try wait(for: "切回中文后仍选中同一条收藏") { list.selectedRow == 1 && list.rowIDAtRow?(1) == .entry(blankID) }
        let beforeCopy = board.changeCount
        guard let copy = list.menu?.item(withTitle: "复制"), let action = copy.action else { throw AppError("未找到复制操作。") }
        NSApp.sendAction(action, to: copy.target, from: copy)
        try wait(for: "无原应用时完成复制并关闭面板") {
            !history.isVisible && board.changeCount != beforeCopy && board.string(forType: .string) == String(space)
        }
        settings.close()

        // 验证默认纯文本复制命令与右键一键忽略来源应用
        let rich = try Tests.richText()
        let richID = HistoryStore.fingerprint(rich)
        guard case let .text(richString, _, _) = rich else { throw AppError("富文本测试数据无效。") }
        try ClipboardAccess(board).write(rich)
        pasteboard.observeSource("com.apple.finder", sequence: board.changeCount)
        try Driver.activate(after: previousApp)
        delegate.showWindow(nil)
        guard let freshPanel = NSApp.keyWindow as? HistoryWindow, let freshRoot = freshPanel.contentView,
              let freshTable = find(HistoryTableView.self, in: freshRoot),
              let freshField = find(NSSearchField.self, in: freshRoot) else {
            throw AppError("无法取得复测面板。")
        }
        defer { freshPanel.orderOut(nil) }
        try wait(for: "富文本收录完成") { freshTable.isEnabled && freshTable.rowIDAtRow?(0) == .entry(richID) }
        freshTable.scrollRowToVisible(0)
        func enterQuery(_ text: String) throws {
            freshPanel.makeFirstResponder(freshField)
            guard let editor = freshField.currentEditor() as? NSTextView else { throw AppError("无法聚焦复测搜索框。") }
            editor.insertText(text, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        }
        func sendKey(_ code: UInt16, _ chars: String, flags: NSEvent.ModifierFlags = []) throws {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: freshPanel.windowNumber, context: nil,
                characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
            else { throw AppError("无法创建复测按键事件。") }
            freshPanel.sendEvent(event)
        }
        freshTable.select(row: 0)
        let richLoc = freshTable.rect(ofRow: 0)
        let richPoint = freshTable.convert(NSPoint(x: richLoc.midX, y: richLoc.midY), to: nil)
        guard let rightEvent = NSEvent.mouseEvent(with: .rightMouseDown, location: richPoint, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: freshPanel.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 0),
              let richMenu = freshTable.menu(for: rightEvent) else {
            throw AppError("无法打开富文本右键菜单。")
        }
        richMenu.delegate?.menuNeedsUpdate?(richMenu)
        guard let ignoreItem = richMenu.items.first(where: { $0.title.contains("忽略来自「") && !$0.isHidden }) else {
            throw AppError("未找到右键忽略来源应用菜单项。")
        }
        richMenu.performActionForItem(at: richMenu.index(of: ignoreItem))
        try wait(for: "右键忽略来源应用并显示提示") {
            preferences.ignoredBundleIDs.contains("com.apple.finder") &&
                find(NSTextField.self, in: freshRoot) { !$0.isHiddenOrHasHiddenAncestor && $0.stringValue.contains("已忽略来自") } != nil
        }
        richMenu.delegate?.menuNeedsUpdate?(richMenu)
        try Tests.expect(ignoreItem.isHidden, "已忽略的应用不再显示忽略菜单项")

        try enterQuery(">plain")
        try wait(for: "匹配默认纯文本命令") { freshTable.isEnabled && freshTable.numberOfRows == 1 }
        try sendKey(36, "\r")
        try wait(for: "开启默认纯文本") { preferences.plainTextByDefault }
        try enterQuery("")
        try wait(for: "恢复列表") { freshTable.isEnabled && freshTable.rowIDAtRow?(0) == .entry(richID) }
        try sendKey(36, "\r", flags: .command)
        try wait(for: "默认纯文本下确认复制去除富文本格式") {
            !freshPanel.isVisible && board.string(forType: .string) == richString &&
                board.data(forType: .html) == nil && board.data(forType: .rtf) == nil
        }
        try Driver.activate(after: previousApp)
        delegate.showWindow(nil)
        try wait(for: "再次唤起以测试 Shift 保留格式") { freshPanel.isKeyWindow && freshTable.isEnabled }
        try sendKey(36, "\r", flags: [.command, .shift])
        try wait(for: "默认纯文本下 Shift+确认键保留原格式") {
            !freshPanel.isVisible && board.data(forType: .html) != nil && board.data(forType: .rtf) != nil
        }
    }
}
