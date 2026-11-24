import AppKit
import CryptoKit
import SQLite3

@MainActor
enum PanelTests {
    final class PreviewEvents: NSObject {
        var popover: NSPopover?
        var openings = 0
        var closings = 0

        override init() {
            super.init()
            for name in [NSPopover.willShowNotification, NSPopover.willCloseNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(record(_:)), name: name, object: nil)
            }
        }

        deinit { NotificationCenter.default.removeObserver(self) }

        @objc func record(_ notification: Notification) {
            if notification.name == NSPopover.willShowNotification {
                popover = notification.object as? NSPopover
                openings += 1
            } else {
                closings += 1
            }
        }
    }

    static func wait(for description: String, timeout: TimeInterval = 5, until condition: () -> Bool) throws {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            guard Date() < deadline else {
                let frontmost = NSWorkspace.shared.frontmostApplication?.localizedName ?? "无"
                throw AppError("等待\(description)超时。前台应用：\(frontmost)，测试应用激活：\(NSApp.isActive)，当前窗口：\(NSApp.keyWindow?.title ?? "无")。")
            }
            if let event = NSApp.nextEvent(matching: .any, until: Date().addingTimeInterval(0.01), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
    }

    static func importBackground(_ url: URL, into store: PanelBackgroundStore) throws {
        var outcome: Result<Void, Error>?
        Task {
            do { try await store.replace(with: url); outcome = .success(()) }
            catch { outcome = .failure(error) }
        }
        try wait(for: "导入背景图片") { outcome != nil }
        try outcome?.get()
    }

    static func find<T: NSView>(_ type: T.Type, in view: NSView, matching: (T) -> Bool = { _ in true }) -> T? {
        if let match = view as? T, matching(match) { return match }
        for subview in view.subviews {
            if let match = find(type, in: subview, matching: matching) { return match }
        }
        return nil
    }

    private static func checkPanelControls(_ driver: Driver, defaults: UserDefaults, initialCursor: NSPoint) throws {
        let window = driver.window
        func checkAnchor(_ cursor: NSPoint) throws {
            guard let screen = NSScreen.screens.first(where: { $0.frame.contains(cursor) }) ?? NSScreen.main else {
                throw AppError("无法取得鼠标所在屏幕。")
            }
            let available = screen.visibleFrame.insetBy(dx: HistoryLayout.screenMargin, dy: HistoryLayout.screenMargin)
            let x = min(max(cursor.x, available.minX), available.maxX - window.frame.width)
            let above = min(max(cursor.y + HistoryLayout.cursorGap, available.minY), available.maxY)
            let below = min(max(cursor.y - HistoryLayout.cursorGap, available.minY), available.maxY)
            try Tests.expect(available.insetBy(dx: -1, dy: -1).contains(window.frame) && abs(window.frame.minX - x) <= 1 &&
                             (abs(window.frame.minY - above) <= 1 || abs(window.frame.maxY - below) <= 1),
                             "面板锚定唤起时的鼠标，面板 \(window.frame)，鼠标 \(cursor)，可用区域 \(available)")
        }
        try checkAnchor(initialCursor)
        guard let screen = window.screen else { throw AppError("无法取得面板所在屏幕。") }
        let bounds = screen.visibleFrame.insetBy(dx: HistoryLayout.screenMargin, dy: HistoryLayout.screenMargin)
        let x = window.frame.midX < bounds.midX ? bounds.maxX - window.frame.width : bounds.minX
        let moved = NSPoint(x: x, y: bounds.minY)
        window.setFrameOrigin(moved)
        try Tests.expect(abs(window.frame.minX - moved.x) <= 1 && abs(window.frame.minY - moved.y) <= 1,
                         "窗口移动到指定位置")
        try driver.press(53, "\u{1b}")
        try wait(for: "移位后关闭面板") { !window.isVisible }
        defaults.set("statusItem", forKey: "popupPosition")
        let cursor = NSEvent.mouseLocation
        driver.delegate.showWindow(nil)
        try wait(for: "移位后重新打开面板") { window.isKeyWindow && driver.table.isEnabled }
        try checkAnchor(cursor)

        let menu = driver.delegate.statusMenu
        let menuIndex = menu.indexOfItem(withTitle: "设置…")
        try Tests.expect(menuIndex >= 0, "菜单栏提供设置入口")
        menu.performActionForItem(at: menuIndex)
        try wait(for: "打开原有设置窗口") { NSApp.keyWindow?.title == "ClipNest 设置" && !window.isVisible }
        guard let settings = NSApp.keyWindow else { throw AppError("无法取得设置窗口。") }
        driver.delegate.showWindow(nil)
        try wait(for: "回到搜索框") { window.isKeyWindow && driver.field.currentEditor() === window.firstResponder }
        guard let gear = find(NSButton.self, in: driver.content, matching: { $0.accessibilityLabel() == "打开设置" }) else {
            throw AppError("无法取得面板底栏的设置齿轮。")
        }
        try driver.click(gear, at: NSPoint(x: gear.bounds.midX, y: gear.bounds.midY))
        try wait(for: "点击齿轮返回同一个设置窗口") { NSApp.keyWindow === settings && !window.isVisible }
        settings.close()
        try driver.openForSearch()
        print("PASS 保留旧偏好时按鼠标定位、移位后重开、点击齿轮返回现有设置窗口")
    }

    static func run(in directory: URL) throws {
        let board = NSPasteboard(name: .init("com.clipnest.panel-tests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let pasteboard = ClipboardAccess(board)
        let key = SymmetricKey(size: .bits256)
        let url = directory.appendingPathComponent("history.db")
        let views = try TestProject.source("HistoryViews")
        let app = try TestProject.source("App")
        let position = try TestProject.source("PopupPosition")
        let db = try HistoryStore(url: url, key: key)
        let storeSource = try TestProject.source("HistoryStore")
        let lines = Set(storeSource.split(separator: "\n").map(String.init)).sorted().prefix(32)
        for line in lines { _ = try db.save(.text(line)) }
        let viewEntry = try db.save(.text(views))
        try db.addFavorite(viewEntry.id)
        _ = try db.save(.text(app))
        _ = try db.save(.text(position))
        _ = try db.load()
        let savedFavoriteDate = db.favorites.first?.date
        let damagedEntry = try db.save(.files([directory.path]))
        var rawDB: OpaquePointer?
        guard sqlite3_open(url.path, &rawDB) == SQLITE_OK else { throw AppError("无法打开面板测试数据库。") }
        defer { sqlite3_close(rawDB) }
        let truncate = "UPDATE records SET text=substr(text,1,length(text)-1) WHERE id='\(damagedEntry.id)'"
        guard sqlite3_exec(rawDB, truncate, nil, nil, nil) == SQLITE_OK else { throw AppError(String(cString: sqlite3_errmsg(rawDB))) }

        let previousApp = NSWorkspace.shared.frontmostApplication
        defer {
            if NSApp.isActive, previousApp?.processIdentifier != getpid() { previousApp?.activate(options: []) }
        }
        Driver.launch()
        func activateTestApp() throws { try Driver.activate(after: previousApp) }
        try activateTestApp()
        let suite = "com.clipnest.panel-tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw AppError("无法创建测试偏好域。") }
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("center", forKey: "popupPosition")
        let preferences = AppSettings(defaults: defaults)
        preferences.language = .simplifiedChinese
        try importBackground(TestProject.icon, into: PanelBackgroundStore(directory: directory))
        let delegate = AppDelegate(clipboard: pasteboard, directory: directory, defaults: defaults,
                                   languageResources: TestProject.resources)
        defer { delegate.applicationWillTerminate(Notification(name: NSApplication.willTerminateNotification)) }
        let initialCursor = NSEvent.mouseLocation
        delegate.startPanel { try HistoryStore(url: url, key: key) }
        let driver = try Driver(delegate: delegate, previousApp: previousApp)
        let window = driver.window, content = driver.content, table = driver.table, field = driver.field
        defer { window.orderOut(nil) }
        let query = driver.query
        func press(_ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = []) throws {
            try driver.press(code, characters, flags: flags)
        }
        let initialRows = lines.count + 3
        try wait(for: "载入原生历史面板") { NSApp.isActive && window.isKeyWindow && table.numberOfRows == initialRows }
        try checkPanelControls(driver, defaults: defaults, initialCursor: initialCursor)
        try Tests.expect(find(NSTextField.self, in: content) { $0.stringValue == "ClipNest" } == nil, "搜索框旁无应用名称")
        let log = try String(contentsOf: directory.appendingPathComponent("errors.log"), encoding: .utf8)
        try Tests.expect(log.contains("部分记录未加载"), "面板加载其余历史并报告损坏记录")
        try Tests.expect(find(NSTextField.self, in: content) { $0.stringValue.contains("部分记录未加载") } == nil, "损坏记录只写入日志")
        let initialCount = board.changeCount
        try query("nsGlassEffectView")
        try press(36, "\r")
        try query("popupPosition")
        try wait(for: "替换搜索结果") { table.isEnabled && table.numberOfRows == 2 }
        try Tests.expect(board.changeCount == initialCount && window.isVisible, "替换搜索词取消等待中的回车")

        try query(" NSGlassEffectView   cornerRadius ")
        try press(36, "\r")
        try wait(for: "从最新搜索结果复制") { board.string(forType: .string) == views && !window.isVisible }
        let updated = try db.load()
        try Tests.expect(updated.first?.id == viewEntry.id && updated.first!.date > viewEntry.date, "重复复制后持久化新的日期和顺序")
        try Tests.expect(db.favorites.first?.date == savedFavoriteDate, "复制历史保留收藏日期")
        print("PASS 原生搜索框连续输入、取消过期回车、立即回车复制当前结果")

        try activateTestApp()
        delegate.showWindow(nil)
        try wait(for: "再次打开历史面板") { NSApp.isActive && window.isKeyWindow }
        try query("popupPosition")
        try press(125, "\u{F701}")
        try press(36, "\r")
        try wait(for: "方向键选择后复制") { board.string(forType: .string) == app }
        try wait(for: "方向键复制后关闭面板") { !window.isVisible }
        try activateTestApp()
        delegate.showWindow(nil)
        try wait(for: "返回搜索框") { NSApp.isActive && window.isKeyWindow }
        try query("NSGlassEffectView")
        try press(18, "1", flags: .function)
        delegate.showWindow(nil)
        try wait(for: "重新唤起并更新搜索") { table.isEnabled && table.numberOfRows == 1 }
        try Tests.expect(board.string(forType: .string) == app && window.isVisible, "再次唤起取消等待中的数字快捷键")

        try press(18, "1", flags: .function)
        delegate.showWindow(nil)
        try wait(for: "复制后保持重新打开的面板") { board.string(forType: .string) == views }
        let nextCopy = try TestProject.source("Models")
        try ClipboardAccess(board).write(.text(nextCopy))
        try query("   ")
        try wait(for: "收录外部复制并保留新面板") { window.isVisible && table.numberOfRows == initialRows + 1 }
        try Tests.expect(field.currentEditor() === window.firstResponder, "后台收录保留搜索焦点")
        print("PASS 原生方向键和 Fn 数字事件、复制期间重新唤起、后续剪贴板变更收录")

        table.selectRowIndexes(IndexSet(integer: 18), byExtendingSelection: false)
        table.scrollRowToVisible(22)
        guard let anchor = table.scrollAnchor() else { throw AppError("无法定位已滚动列表的首行。") }
        let readme = try String(contentsOf: TestProject.root.appendingPathComponent("README.md"), encoding: .utf8)
        try ClipboardAccess(board).write(.text(readme))
        try wait(for: "滚动时收录新记录") { table.numberOfRows == initialRows + 2 }
        try Tests.expect(table.scrollAnchor()?.id == anchor.id && table.scrollAnchor()?.offset == anchor.offset, "收录时保留首行内容和滚动偏移")
        try Tests.expect(table.selectedRow == 19, "后台收录保留选中的记录")

        let clickRow = table.rows(in: table.visibleRect).location + 1
        let clicked = try db.load()[clickRow]
        guard case let .text(clickedText) = clicked.content else { throw AppError("点击行应为文本。") }
        let rect = table.rect(ofRow: clickRow)
        try driver.click(table, at: NSPoint(x: rect.midX, y: rect.midY))
        do {
            try wait(for: "点击可见记录复制") { !window.isVisible && board.string(forType: .string) == clickedText }
        } catch {
            let actual = try ClipboardAccess(board).read().map(HistoryStore.fingerprint) ?? "无"
            throw AppError("\(error.localizedDescription) 点击第 \(clickRow) 行，预期 \(clicked.id)，剪贴板 \(actual)，面板可见 \(window.isVisible)，选中行 \(table.selectedRow)。")
        }
        print("PASS 后台收录保留选择和滚动位置、单击当前可见行复制")

        try activateTestApp()
        delegate.showWindow(nil)
        try wait(for: "快速复制前面板就绪") { window.isKeyWindow && table.isEnabled }
        let fresh = try TestProject.source("HistorySearch")
        try ClipboardAccess(board).write(.text(fresh))
        // 连续执行写入和选取，不给主线程轮询定时器处理这次变更的机会。
        try press(18, "1", flags: .function)
        try wait(for: "回填旧历史") { !window.isVisible && board.string(forType: .string) == clickedText }
        let afterRestore = try db.load()
        try Tests.expect(afterRestore.count >= 2 && afterRestore[0].id == clicked.id && afterRestore[1].content == .text(fresh),
            "轮询前回填旧记录，仍可从数据库找回刚复制的内容")
        print("PASS 轮询前选择旧历史保留最新外部复制")

        let image = try Tests.icon()
        let imageID = HistoryStore.fingerprint(image)
        try ClipboardAccess(board).write(image)
        try activateTestApp()
        delegate.showWindow(nil)
        try wait(for: "图片收录并显示") { window.isKeyWindow && table.rowIDAtRow?(0) == .entry(imageID) }
        table.scrollRowToVisible(0)
        func pointerEvent(_ type: NSEvent.EventType, row: Int) throws -> NSEvent {
            try driver.pointerEvent(type, row: row)
        }
        let events = PreviewEvents()
        guard let menu = table.menu(for: try pointerEvent(.rightMouseDown, row: 0)),
              let previewItem = menu.item(withTitle: "查看内容") else { throw AppError("未找到图片行的查看内容菜单项。") }
        menu.performActionForItem(at: menu.index(of: previewItem))
        try wait(for: "显示图片预览") { events.popover?.isShown == true }
        let neighboringRow = try pointerEvent(.mouseMoved, row: 1)
        table.mouseMoved(with: neighboringRow)
        try press(34, "i", flags: .command)
        try wait(for: "再次按 ⌘I 关闭预览") { events.popover?.isShown == false }
        try press(49, " ")
        try wait(for: "空搜索按空格打开预览") { events.popover?.isShown == true }
        try press(125, "\u{F701}")
        try wait(for: "方向键原地跟随切换预览") {
            table.selectedRow == 1 && events.popover?.isShown == true && events.closings == 1
        }
        try press(49, " ")
        try wait(for: "再按空格关闭预览") { events.popover?.isShown == false }
        table.mouseMoved(with: neighboringRow)
        try Tests.expect(window.isVisible && table.selectedRow == 1, "关闭预览后恢复悬停选择")

        // 非空搜索框中空格正常输入、⌘⌫ 清空输入；空搜索时 ⌘⌫ 删除记录并支持 ⌘Z 撤销。
        let beforeDeleteCount = table.numberOfRows
        let rowZeroID = table.rowIDAtRow?(0)
        try query("a")
        try press(49, " ")
        try wait(for: "非空搜索按空格输入字符而非触发预览") {
            field.stringValue == "a " && events.popover?.isShown == false
        }
        try press(51, "\u{7f}", flags: .command)
        try wait(for: "非空搜索按 ⌘⌫ 清空搜索词而不删除记录") {
            field.stringValue.isEmpty && table.isEnabled && table.numberOfRows == beforeDeleteCount
        }
        table.select(row: 0)
        try press(51, "\u{7f}", flags: .command)
        try wait(for: "空搜索按 ⌘⌫ 删除记录并展示撤销提示") {
            table.isEnabled && table.numberOfRows == beforeDeleteCount - 1 &&
                find(NSTextField.self, in: content) { !$0.isHiddenOrHasHiddenAncestor && $0.stringValue.contains("⌘Z") } != nil
        }
        try press(6, "z", flags: .command)
        try wait(for: "按 ⌘Z 撤销删除") {
            table.isEnabled && table.numberOfRows == beforeDeleteCount && table.rowIDAtRow?(0) == rowZeroID
        }
        guard let pauseMenu = delegate.statusMenu.item(withTitle: "暂停记录") else { throw AppError("未找到暂停记录菜单。") }
        delegate.statusMenu.performActionForItem(at: delegate.statusMenu.index(of: pauseMenu))
        let isPausedBanner: (PanelBannerView) -> Bool = { $0.actionButton.accessibilityLabel() == L("恢复记录") }
        try wait(for: "暂停时显示面板横幅") {
            preferences.paused && find(PanelBannerView.self, in: content) { isPausedBanner($0) && !$0.isHidden } != nil
        }
        guard let banner = find(PanelBannerView.self, in: content, matching: isPausedBanner) else { throw AppError("未找到暂停横幅。") }
        banner.actionButton.performClick(nil)
        try wait(for: "点击横幅恢复按钮取消暂停") { !preferences.paused && banner.isHidden }
        print("PASS 空格/⌘I 预览开关与跟随、搜索框 ⌘⌫ 保护与 ⌘Z 撤销、暂停横幅恢复")

        try checkSettingsAndShortcuts(driver: driver, preferences: preferences, defaults: defaults, board: board,
                                      url: url, directory: directory, views: views, app: app, previousApp: previousApp)
        try checkCommandsAndLanguage(driver: driver, preferences: preferences, board: board, pasteboard: pasteboard,
                                     db: db, views: views, position: position, previousApp: previousApp)
    }
}
