import AppKit
import CryptoKit

@MainActor
enum HistoryRowTests {
    static func footerLayout(_ directory: URL) throws {
        let resources = TestProject.resources
        defer { L10n.select(.system) }
        for language in [AppLanguage.english, .simplifiedChinese] {
            L10n.select(language, resources: resources)
            let listButton = FooterButton(title: L("查看收藏"), shortcut: "⌘ L", target: NSApp, action: #selector(NSApplication.hide(_:)))
            let clearButton = FooterButton(title: L("清空历史"), shortcut: "⌥⌘⌫", target: NSApp, action: #selector(NSApplication.hide(_:)))
            let panel = HistoryPanelView(listButton: listButton, clearButton: clearButton)
            defer { panel.window.close() }
            try Tests.expect(!panel.window.hidesOnDeactivate && panel.window.animationBehavior == .none,
                             "面板禁用失活隐式隐藏与默认出现动画，避免唤起时闪现旧位置")
            panel.operation.isHidden = true
            func footerButtons(in view: NSView) -> [FooterButton] {
                if let button = view as? FooterButton { return [button] }
                return view.subviews.flatMap { footerButtons(in: $0) }
            }
            guard let quitButton = footerButtons(in: panel.surface).first(where: { $0.title == L("退出") })
            else { throw AppError("无法定位底栏的退出按钮。") }
            let gear = panel.settingsButton
            let buttons: [NSButton] = [listButton, gear, clearButton, quitButton]
            try Tests.expect(gear.title.isEmpty && gear.image != nil && gear.imagePosition == .imageOnly &&
                             gear.accessibilityLabel() == L("打开设置") && gear.toolTip == "⌘," &&
                             gear.accessibilityHelp()?.contains("⌘,") == true,
                             "设置齿轮提供当前语言的说明与快捷键")
            for width in [CGFloat(360), CGFloat(460)] {
                panel.window.setContentSize(NSSize(width: width, height: HistoryLayout.minimumHeight))
                for title in [L("查看收藏"), L("返回历史")] {
                    listButton.title = title
                    panel.window.contentView?.layoutSubtreeIfNeeded()
                    let frames = buttons.map { $0.convert($0.bounds, to: panel.surface) }
                    try Tests.expect(frames.allSatisfy { panel.surface.bounds.contains($0) && abs($0.height - 26) < 0.5 &&
                        abs($0.midY - frames[0].midY) < 0.5 }, "两种语言及面板宽度下，四个按钮均完整显示在同一行")
                    try Tests.expect(abs(frames[1].minX - frames[0].maxX - 4) < 0.5 && abs(frames[1].width - 28) < 0.5 &&
                                     frames[1].maxX + 4 <= frames[2].minX && abs(frames[3].minX - frames[2].maxX - 4) < 0.5,
                                     "收藏与设置位于左侧，清空与退出位于右侧，齿轮占 28 × 26 点")
                    for (button, shortcut) in zip([listButton, clearButton, quitButton], ["⌘ L", "⌥⌘⌫", "⌘ Q"]) {
                        try Tests.expect(button.frame.width >= button.intrinsicContentSize.width &&
                            button.toolTip?.contains(button.title) == true && button.toolTip?.contains(shortcut) == true &&
                            button.accessibilityHelp()?.contains(shortcut) == true, "底栏标题显示完整，悬停和辅助功能提供快捷键")
                    }
                    try Tests.expect((panel.table.enclosingScrollView?.frame.height ?? 0) >= 64,
                                     "160 点高的面板仍可显示至少 64 点列表")
                    guard let header = panel.search.superview, let parent = header.superview else {
                        throw AppError("无法定位搜索栏。")
                    }
                    let searchRect = panel.search.convert(panel.search.bounds, to: header)
                    let input = header.convert(NSPoint(x: searchRect.midX, y: searchRect.midY), to: parent)
                    let margin = header.convert(NSPoint(x: 2, y: header.bounds.midY), to: parent)
                    try Tests.expect(header.subviews == [panel.search] && searchRect.width >= header.bounds.width - 20 &&
                                     header.hitTest(input)?.isDescendant(of: panel.search) == true && header.hitTest(margin) === header &&
                                     header.mouseDownCanMoveWindow && panel.window.isMovableByWindowBackground,
                                     "搜索框独占顶栏且能编辑，两侧留白可拖动窗口")
                    panel.accessibilityBanner.isHidden = false
                    panel.window.contentView?.layoutSubtreeIfNeeded()
                    let grantFrame = panel.grantAccessibilityButton.convert(panel.grantAccessibilityButton.bounds, to: panel.accessibilityBanner)
                    try Tests.expect(panel.accessibilityBanner.bounds.contains(grantFrame) &&
                                     panel.grantAccessibilityButton.frame.width >= panel.grantAccessibilityButton.intrinsicContentSize.width &&
                                     panel.grantAccessibilityButton.accessibilityLabel() == L("打开辅助功能设置"),
                                     "辅助功能提示横幅在 \(Int(width)) 点宽与当前语言下完整显示授权按钮")
                    panel.accessibilityBanner.isHidden = true
                }
            }
        }
    }

    static func render(_ directory: URL) throws {
        let window = HistoryWindow(contentRect: NSRect(x: 0, y: 0, width: HistoryLayout.width, height: 90),
                                   styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let surface = window.installSurface()
        let cell = HistoryCell(frame: NSRect(x: 0, y: 0, width: HistoryLayout.width, height: HistoryLayout.textRowHeight))
        surface.addSubview(cell)
        let store = try HistoryStore(url: directory.appendingPathComponent("history.db"), key: SymmetricKey(size: .bits256))
        let file = TestProject.root.appendingPathComponent("macOS/Sources/HistoryPanelController.swift")
        let code = try String(contentsOf: file, encoding: .utf8)
        let source = "com.apple.finder"
        let entry = try store.save(.text(code), sourceApp: source)
        let range = (entry.preview as NSString).range(of: "import")
        try Tests.expect(range.location != NSNotFound, "预览包含源文件的 import")
        cell.configure(entry: entry, row: 0, isFavorite: true, numberShortcut: .fn, highlightRanges: [range])
        func visibleViews(_ view: NSView) -> [NSView] {
            guard !view.isHidden else { return [] }
            return [view] + view.subviews.flatMap(visibleViews)
        }
        func checkShortcut(_ cell: NSTableCellView, text: String) throws {
            cell.layoutSubtreeIfNeeded()
            guard let hint = visibleViews(cell).compactMap({ $0 as? NSTextField }).first(where: { $0.stringValue == text }) else {
                throw AppError("未找到数字快捷键提示。")
            }
            // NSTextField 的外框包含左右绘制边距，Auto Layout 将可见文字的对齐矩形固定在行内。
            guard let parent = hint.superview else { throw AppError("数字快捷键没有所属视图。") }
            let right = parent.convert(hint.alignmentRect(forFrame: hint.frame), to: cell).maxX
            try Tests.expect(abs(right - (cell.bounds.maxX - HistoryLayout.rowInset)) < 0.5 && hint.alignment == .right,
                             "\(type(of: cell)) 的 \(text) 固定在行右边：行 \(cell.bounds)，标签右边 \(right)，对齐方式 \(hint.alignment.rawValue)")
        }
        let labels = visibleViews(cell).compactMap { $0 as? NSTextField }.map(\.stringValue)
        try Tests.expect(Set(labels) == Set([entry.preview, "fn 1"]), "代码行只显示正文与数字快捷键文字")
        let sourceName = AppMetadataCache.shared.displayName(for: source)
        try Tests.expect(cell.accessibilityLabel()?.contains(sourceName) == true, "隐藏来源图标时仍可读出来源名称")
        try Tests.expect(visibleViews(cell).contains { $0 is NSImageView && $0.toolTip == L("已收藏") },
                         "历史列表中已收藏条目显示星标")
        cell.configure(entry: entry, row: 0, isFavorite: true, inFavoritesList: true, numberShortcut: .fn, highlightRanges: [range])
        try Tests.expect(!visibleViews(cell).contains { $0 is NSImageView && $0.toolTip == L("已收藏") },
                         "收藏列表中不重复显示星标")
        cell.configure(entry: entry, row: 0, isFavorite: true, numberShortcut: .fn, highlightRanges: [range])
        try checkShortcut(cell, text: "fn 1")
        guard let background = NSImage(contentsOf: TestProject.icon) else {
            throw AppError("无法打开项目图片。")
        }
        surface.setBackground(background, intensity: 8)
        for mode in [PanelAppearance.dark, .light] {
            window.applyAppearance(mode)
            window.displayIfNeeded()
            cell.layoutSubtreeIfNeeded()
            guard let field = cell.textField, let bitmap = surface.bitmapImageRepForCachingDisplay(in: surface.bounds) else {
                throw AppError("无法绘制原生面板。")
            }
            surface.cacheDisplay(in: surface.bounds, to: bitmap)
            guard let color = bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB) else {
                throw AppError("无法读取面板底色。")
            }
            try Tests.expect(mode == .dark ? color.redComponent < 0.3 : color.redComponent > 0.7, "自定义图片随面板外观切换底色")
            try Tests.expect(field.bounds.width > 100 && field.lineBreakMode == .byTruncatingMiddle, "460 点宽面板为正文保留空间")
            try Tests.expect(field.attributedStringValue.attribute(.backgroundColor, at: range.location, effectiveRange: nil) != nil,
                             "正文呈现指定字符区间的高亮")
        }
        let color = Payload.text("#108EE9")
        let savedColor = try store.save(color)
        guard let colorEntry = try store.load().first(where: { $0.id == savedColor.id }) else {
            throw AppError("未找到重新加载的色值记录。")
        }
        let blue = ClipboardColor(red: 16 / 255, green: 142 / 255, blue: 233 / 255, alpha: 1)
        try Tests.expect(colorEntry.colorPreview == blue && colorEntry.preview == "#108EE9", "旧记录可按原文计算色块")
        try Tests.expect(try store.payload(for: colorEntry.id) == color, "带色块的记录仍完整复制原文")
        try Tests.expect(ClipboardColor.parse(.text("rgb(16 142 233)")) == blue &&
                         ClipboardColor.parse(.text("hsl(120 100% 50% / 40%)")) ==
                             ClipboardColor(red: 0, green: 1, blue: 0, alpha: 0.4) &&
                         ClipboardColor.parse(.text("color: #108EE9;")) == nil, "识别独立颜色并保留代码文本")
        cell.configure(entry: colorEntry, row: 1, isFavorite: false, numberShortcut: .fn)
        try checkShortcut(cell, text: "fn 2")
        guard let swatch = visibleViews(cell).compactMap({ $0 as? ColorSwatchView }).first else {
            throw AppError("没有显示色块。")
        }
        try Tests.expect(swatch.frame.maxX < (cell.textField?.frame.minX ?? 0), "色块显示在正文左侧")

        let richEntry = try store.save(try Tests.richText())
        cell.configure(entry: richEntry, row: 2, isFavorite: false, numberShortcut: .fn)
        try Tests.expect(!visibleViews(cell).contains { $0 is NSImageView }, "富文本正文没有格式图标")

        let shortEntry = try store.save(.text(file.lastPathComponent), sourceApp: source)
        let imageEntry = try store.save(Tests.icon(), sourceApp: source)
        for width in [CGFloat(360), CGFloat(460)] {
            cell.setFrameSize(NSSize(width: width, height: HistoryLayout.imageRowHeight))
            for (item, row, favorite) in [(entry, 0, true), (shortEntry, 1, false), (imageEntry, 9, false)] {
                cell.configure(entry: item, row: row, isFavorite: favorite, numberShortcut: .fn)
                cell.layoutSubtreeIfNeeded()
                let icons = visibleViews(cell).compactMap { $0 as? NSImageView }
                let expected = (favorite ? 1 : 0) + (item.thumbnail != nil ? 1 : 0)
                try Tests.expect(icons.count == expected && cell.accessibilityLabel()?.contains(sourceName) == true,
                                 "长短文本、收藏和图片均不显示来源图标，同时保留辅助功能来源名称")
            }
        }

        let record = try store.save(.files([file.path]))
        cell.configure(entry: record, row: 8, isFavorite: false, numberShortcut: .fn)
        try Tests.expect(!visibleViews(cell).contains { $0 is NSImageView }, "复用行时清除来源图标与状态微标")
        try Tests.expect(swatch.isHidden && swatch.color == nil, "复用行时清除色块")
        cell.setFrameSize(NSSize(width: 360, height: HistoryLayout.textRowHeight))
        try checkShortcut(cell, text: "fn 9")
        let commandCell = PanelCommandCell(frame: cell.frame)
        surface.addSubview(commandCell)
        commandCell.configure(command: .history, title: L("返回历史"), shortcut: "fn 1")
        try checkShortcut(commandCell, text: "fn 1")
        try checkContextMenuBorder()
    }

    private final class ContextMenuProbe: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSMenuDelegate {
        var opened = false
        var leftEdgeAlpha: CGFloat = -1
        var centerAlpha: CGFloat = -1
        weak var table: HistoryTableView?

        func numberOfRows(in tableView: NSTableView) -> Int { 1 }
        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? { NSView() }
        func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { HistoryRowView() }
        func tableView(_ tableView: NSTableView, heightOfRow row: Int) -> CGFloat { HistoryLayout.textRowHeight }

        func menuWillOpen(_ menu: NSMenu) {
            opened = true
            if let table, let rep = table.bitmapImageRepForCachingDisplay(in: table.bounds) {
                table.cacheDisplay(in: table.bounds, to: rep)
                let y = rep.pixelsHigh / 2
                leftEdgeAlpha = (0..<2).compactMap { rep.colorAt(x: $0, y: y)?.usingColorSpace(.deviceRGB)?.alphaComponent }.max() ?? -1
                centerAlpha = rep.colorAt(x: rep.pixelsWide / 2, y: y)?.usingColorSpace(.deviceRGB)?.alphaComponent ?? -1
            }
            menu.cancelTrackingWithoutAnimation()
        }
    }

    private static func checkContextMenuBorder() throws {
        let window = HistoryWindow(contentRect: NSRect(x: 100, y: 100, width: HistoryLayout.width, height: HistoryLayout.textRowHeight),
                                   styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: HistoryLayout.width, height: HistoryLayout.textRowHeight))
        scroll.drawsBackground = false
        let table = HistoryTableView(frame: scroll.bounds)
        let probe = ContextMenuProbe()
        probe.table = table
        table.addTableColumn(NSTableColumn(identifier: .init("entry")))
        table.headerView = nil
        table.backgroundColor = .clear
        table.intercellSpacing = .zero
        table.style = .plain
        table.rowSizeStyle = .custom
        table.dataSource = probe
        table.delegate = probe

        let menu = NSMenu()
        menu.delegate = probe
        menu.addItem(withTitle: L("复制"), action: nil, keyEquivalent: "")
        table.menu = menu
        scroll.documentView = table
        window.contentView = scroll
        table.reloadData()
        scroll.layoutSubtreeIfNeeded()

        let rect = table.rect(ofRow: 0)
        let point = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
        guard let event = NSEvent.mouseEvent(with: .rightMouseDown, location: point, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
            eventNumber: 1, clickCount: 1, pressure: 0) else {
            throw AppError("无法创建右键测试事件。")
        }
        table.rightMouseDown(with: event)
        try Tests.expect(probe.opened && table.selectedRow == 0, "右键弹出菜单并选中对应行")
        try Tests.expect(probe.leftEdgeAlpha == 0 && probe.centerAlpha > 0.5,
                         "右键菜单不绘制外围蓝色边框且保留行选中背景：edge=\(probe.leftEdgeAlpha), center=\(probe.centerAlpha)")
    }
}
