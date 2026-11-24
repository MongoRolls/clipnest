import AppKit
import CryptoKit

extension PanelTests {
    static func imageText(in directory: URL) throws {
        let board = NSPasteboard(name: .init("com.clipnest.ocr-panel.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let suite = "com.clipnest.ocr-panel.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw AppError("无法创建图片文字测试偏好。") }
        defer { defaults.removePersistentDomain(forName: suite); L10n.select(.system) }
        let preferences = AppSettings(defaults: defaults)
        preferences.language = .simplifiedChinese
        try preferences.setKeyboard(KeyboardSettings(confirm: .commandEnter))

        let previousApp = NSWorkspace.shared.frontmostApplication
        defer {
            if NSApp.isActive, previousApp?.processIdentifier != getpid() { previousApp?.activate(options: []) }
        }
        Driver.launch()
        try Driver.activate(after: previousApp)
        let url = directory.appendingPathComponent("history.db"), key = SymmetricKey(size: .bits256)
        let db = try HistoryStore(url: url, key: key)
        let delegate = AppDelegate(clipboard: ClipboardAccess(board), directory: directory, defaults: defaults,
                                   languageResources: TestProject.resources)
        defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
        delegate.startPanel { try HistoryStore(url: url, key: key) }
        let driver = try Driver(delegate: delegate, previousApp: previousApp)
        let window = driver.window, content = driver.content, table = driver.table
        defer { window.orderOut(nil) }
        let events = PreviewEvents()
        let screenshot = try ImageOCRTests.picture("ClipNest Documents")
        let screenshotID = HistoryStore.fingerprint(screenshot)
        try ClipboardAccess(board).write(screenshot)
        try driver.openForSearch()
        try driver.query("type:image Documents")
        try wait(for: "后台识别后通过图中文字找到图片", timeout: 30) {
            table.isEnabled && table.numberOfRows == 1 && table.rowIDAtRow?(0) == .entry(screenshotID)
        }
        try Tests.expect(abs(window.frame.height - HistoryLayout.minimumHeight) < 0.5,
                         "仅一张搜索结果时面板以单行底栏的最小高度展示")
        guard let indexed = try db.load().first(where: { $0.id == screenshotID }), let recognized = indexed.ocrText,
              let imageMenu = table.menu(for: try driver.pointerEvent(.rightMouseDown, row: 0)),
              let extractImageText = imageMenu.item(withTitle: "提取图中文字") else { throw AppError("未找到索引或图片文字菜单。") }
        imageMenu.delegate?.menuNeedsUpdate?(imageMenu)
        try Tests.expect(recognized.localizedCaseInsensitiveContains("documents") && !extractImageText.isHidden &&
                         imageMenu.item(withTitle: "复制为纯文本")?.isHidden == true, "图片菜单只提供适用的文字提取操作")
        try driver.press(34, "i", flags: .command)
        try wait(for: "已索引图片的预览") { events.popover?.isShown == true }
        guard let popover = events.popover, let preview = popover.contentViewController?.view,
              let showText = find(NSButton.self, in: preview, matching: { $0.title == "查看文字" }) else {
            throw AppError("未找到已识别图片的查看文字按钮。")
        }
        let originalHeight = popover.contentSize.height
        showText.performClick(nil)
        try wait(for: "展开可选择的图片文字") {
            popover.contentSize.height > originalHeight && showText.title == "复制文字" &&
                find(NSTextView.self, in: preview) { $0.isSelectable && !$0.isEditable && $0.string == recognized } != nil
        }
        showText.performClick(nil)
        try wait(for: "从预览复制文字并保留面板") { window.isVisible && table.isEnabled && board.string(forType: .string) == recognized }
        try driver.press(53, "\u{1b}")
        try wait(for: "关闭图文预览") { !popover.isShown && table.isEnabled }
        let copiedVersion = board.changeCount
        imageMenu.performActionForItem(at: imageMenu.index(of: extractImageText))
        try wait(for: "右键提取图中文字并关闭面板") {
            !window.isVisible && board.changeCount != copiedVersion && board.string(forType: .string) == recognized
        }
        try Tests.expect(try db.load().first(where: { $0.id == screenshotID })?.date == indexed.date,
                         "提取图中文字保留原图的使用时间")
        print("PASS 后台图文搜索、预览查看及复制、右键提取图中文字保留原图")

        let menuIndex = delegate.statusMenu.indexOfItem(withTitle: "设置…")
        try Tests.expect(menuIndex >= 0, "可从菜单栏进入历史设置")
        delegate.statusMenu.performActionForItem(at: menuIndex)
        try wait(for: "历史设置窗口获得焦点") { NSApp.keyWindow?.title == "ClipNest 设置" && !window.isVisible }
        guard let settingsWindow = NSApp.keyWindow, let settingsController = settingsWindow.windowController as? SettingsWindowController
        else { throw AppError("无法取得设置窗口。") }
        defer { settingsWindow.close() }
        settingsController.selectPane(.history)
        guard let historyPage = settingsController.currentPageView,
              let autoOCR = find(NSSwitch.self, in: historyPage, matching: { $0.accessibilityLabel() == "搜索图片中的文字" })
        else { throw AppError("未找到自动识别开关。") }
        try Tests.expect(autoOCR.state == .on, "新安装默认开启自动识别")
        autoOCR.performClick(nil)
        try Tests.expect(!preferences.imageOCR, "可在历史设置中关闭后台识别")
        settingsWindow.orderOut(nil)

        let manual = try ImageOCRTests.picture("Orchard Receipt")
        let manualID = HistoryStore.fingerprint(manual)
        try ClipboardAccess(board).write(manual)
        try driver.openForSearch()
        try wait(for: "关闭自动识别后仍收录截图") { table.rowIDAtRow?(0) == .entry(manualID) }
        table.select(row: 0)
        try Tests.expect(try db.load().first(where: { $0.id == manualID })?.ocrText == nil, "新截图尚未建索引")
        let manualVersion = board.changeCount
        try driver.press(36, "\r", flags: [.command, .shift])
        try driver.press(53, "\u{1b}")
        delegate.showWindow(nil)
        try wait(for: "取消识别后重新获得搜索焦点") { NSApp.isActive && window.isKeyWindow }
        try driver.query("type:image Orchard")
        try wait(for: "过期手动操作依然完成本地索引", timeout: 30) {
            window.isKeyWindow && table.isEnabled && table.rowIDAtRow?(0) == .entry(manualID)
        }
        try Tests.expect(board.changeCount == manualVersion, "重新唤起面板取消旧识别请求的剪贴板回填")
        try driver.press(36, "\r", flags: [.command, .shift])
        try wait(for: "Shift 加自定义确认键复制缓存文字") {
            !window.isVisible && board.string(forType: .string)?.localizedCaseInsensitiveContains("Orchard") == true
        }
        let blankPicture = try ImageOCRTests.picture("")
        let blankPictureID = HistoryStore.fingerprint(blankPicture)
        try ClipboardAccess(board).write(blankPicture)
        try driver.openForSearch()
        try wait(for: "空白图像可选") { table.rowIDAtRow?(0) == .entry(blankPictureID) }
        table.select(row: 0)
        let blankVersion = board.changeCount
        try driver.press(34, "i", flags: .command)
        try wait(for: "未索引图片的预览") { events.popover?.isShown == true }
        guard let blankPreview = events.popover?.contentViewController?.view,
              let extract = find(NSButton.self, in: blankPreview, matching: { $0.title == "提取文字" })
        else { throw AppError("未找到手动提取入口。") }
        _ = extract.sendAction(extract.action, to: extract.target)
        try Tests.expect(!extract.isEnabled && extract.title == "正在识别…", "识别期间禁用提取按钮")
        try driver.press(53, "\u{1b}", throughApp: true)
        try wait(for: "关闭正在识别的预览") { events.popover?.isShown == false }
        try driver.openForSearch()
        try wait(for: "关闭预览后重新选取空白图像") {
            NSApp.isActive && window.isKeyWindow && table.isEnabled && table.rowIDAtRow?(0) == .entry(blankPictureID)
        }
        table.select(row: 0)
        try driver.press(36, "\r", flags: [.command, .shift], throughApp: true)
        try wait(for: "空白图像提示", timeout: 30) {
            find(NSTextField.self, in: content) { !$0.isHiddenOrHasHiddenAncestor && $0.stringValue == "图中未识别到文字。" } != nil
        }
        try Tests.expect(board.changeCount == blankVersion && window.isVisible &&
                         window.minSize.height > HistoryLayout.minimumHeight &&
                         (table.enclosingScrollView?.frame.height ?? 0) >= 64, "空结果保留剪贴板和面板，并为提示留足高度")
        try Tests.expect(events.popover?.isShown == false && extract.title == "正在识别…",
                         "已关闭的预览丢弃迟到的识别结果")
        print("PASS 关闭后台识别后的手动提取、自定义快捷键、过期请求与空结果")
    }
}
