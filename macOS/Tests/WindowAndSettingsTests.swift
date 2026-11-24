import AppKit
import Carbon

@MainActor
enum WindowAndSettingsTests {
    static func settingsAndLanguage(_ directory: URL) throws {
        let suite = "com.clipnest.preferences-tests.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw AppError("无法创建测试偏好域。") }
        defer {
            defaults.removePersistentDomain(forName: suite)
            L10n.select(.system)
        }
        defaults.set("statusItem", forKey: "popupPosition")
        let settings = AppSettings(defaults: defaults)
        try Tests.expect(settings.appearance == .system &&
            settings.keyboard == KeyboardSettings() && settings.language == .system &&
            settings.directPaste && !settings.plainTextByDefault && !settings.paused && settings.imageOCR &&
            settings.ignoredBundleIDs == AppSettings.defaultIgnoredBundleIDs && settings.historyLimit == 50, "初始偏好")
        var changed: [AppSettings.Key] = []
        settings.onChange = { changed.append($0) }
        settings.appearance = .light
        settings.appearance = .light
        settings.directPaste = false
        settings.directPaste = false
        settings.plainTextByDefault = true
        settings.paused = true
        settings.imageOCR = false
        settings.imageOCR = false
        settings.ignoredBundleIDs = ["com.apple.finder"]
        settings.language = .english
        try Tests.expect(changed == [.appearance, .directPaste, .plainTextByDefault, .paused, .imageOCR, .ignoredBundleIDs, .language], "偏好变化按提交顺序通知")
        let read = AppSettings(defaults: defaults)
        try Tests.expect(read.appearance == .light && !read.directPaste && read.plainTextByDefault && read.paused && read.ignoredBundleIDs == ["com.apple.finder"] &&
                   !read.imageOCR && read.language == .english && defaults.stringArray(forKey: "AppleLanguages") == ["en"], "重新读取偏好")
        try Tests.expect(defaults.string(forKey: "popupPosition") == "statusItem", "调整其他偏好后保留旧版位置值")
        read.directPaste = true
        read.imageOCR = true
        try Tests.expect(AppSettings(defaults: defaults).directPaste && AppSettings(defaults: defaults).imageOCR, "重新开启直接粘贴和自动识别后保存偏好")
        read.language = .system
        try Tests.expect(defaults.persistentDomain(forName: suite)?["AppleLanguages"] == nil, "跟随系统时移除本应用的语言覆盖")
        let resources = TestProject.resources
        L10n.select(.english, resources: resources)
        try Tests.expect(L("界面语言") == "Interface language" && L10n.locale.language.languageCode?.identifier == "en", "读取英语语言包")
        try Tests.expect(L("%d 条", 17).contains("17") && !L("%d 条", 17).contains("条"), "替换英语文案中的数量")
        L10n.select(.english, resources: directory)
        try Tests.expect(L("界面语言") == "界面语言" && L("%d 条", 17) == "17 条", "无资源包时显示中文格式串")
    }

    static func windowEvents(_ directory: URL) throws {
        let panel = HistoryWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 190),
                                  styleMask: [.borderless, .resizable], backing: .buffered, defer: false)
        let material = NSVisualEffectView()
        panel.contentView = material
        panel.applyRoundedCorners()
        guard let data = material.maskImage?.tiffRepresentation, let bitmap = NSBitmapImageRep(data: data)
        else { throw AppError("无法读取原生圆角遮罩。") }
        for x in [0, bitmap.pixelsWide - 1] {
            for y in [0, bitmap.pixelsHigh - 1] {
                try Tests.expect(bitmap.colorAt(x: x, y: y)?.alphaComponent == 0, "四角材质遮罩透明")
            }
        }
        try Tests.expect(bitmap.colorAt(x: bitmap.pixelsWide / 2, y: bitmap.pixelsHigh / 2)?.alphaComponent == 1, "遮罩中央不透明")
        let editor = NSTextView(frame: material.bounds)
        material.addSubview(editor)
        try Tests.expect(panel.makeFirstResponder(editor), "编辑器获得焦点")
        var intercepted = false
        panel.keyAction = { _ in intercepted = true; return true }
        guard let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
            windowNumber: panel.windowNumber, context: nil, characters: "\u{1b}", charactersIgnoringModifiers: "\u{1b}",
            isARepeat: false, keyCode: UInt16(kVK_Escape)) else { throw AppError("无法创建 Esc 事件。") }
        editor.setMarkedText(String(try TestProject.source("App").prefix(2)), selectedRange: NSRange(location: 2, length: 0),
                             replacementRange: NSRange(location: NSNotFound, length: 0))
        try Tests.expect(editor.hasMarkedText(), "原生编辑器进入组合输入")
        panel.sendEvent(escape)
        try Tests.expect(!intercepted, "组合输入期间的 Esc 交给编辑器")
        editor.unmarkText()
        panel.sendEvent(escape)
        try Tests.expect(intercepted, "组合结束后恢复快捷键")
    }

    static func placement(_ directory: URL) throws {
        // 纯几何边界由 ClipNestCoreTests/PanelPlacementTests 覆盖，这里验证面板默认边距与间隔的桥接包装。
        let visible = NSRect(x: -1440, y: 25, width: 1440, height: 875)
        let full = NSSize(width: HistoryLayout.width, height: HistoryLayout.height)
        let short = NSSize(width: HistoryLayout.width, height: HistoryLayout.minimumHeight)
        let cursor = NSPoint(x: -900, y: 800)
        let frame = PanelPlacement(cursor: cursor, visibleFrame: visible, height: full.height).frame(for: full)
        try Tests.expect(frame.origin.x == cursor.x && frame.maxY == cursor.y - HistoryLayout.cursorGap && frame.size == full,
                         "默认间隔包装透传 HistoryLayout.cursorGap")
        let dragged = NSRect(x: -1300, y: 280, width: full.width, height: 350)
        let restored = PanelPlacement.afterDrag(current: dragged, height: full.height, visibleFrame: visible)
        let area = visible.insetBy(dx: HistoryLayout.screenMargin, dy: HistoryLayout.screenMargin)
        try Tests.expect(restored.minX == dragged.minX && area.contains(restored) && restored.minY == area.minY &&
                         PanelPlacement.afterDrag(current: dragged, height: short.height, visibleFrame: visible).maxY == dragged.maxY,
                         "拖动后重排包装透传 HistoryLayout.screenMargin")
    }

    static func model(_ directory: URL) throws {
        let original = try TestProject.source("App")
        for length in [179, 180, 181, 11_999, 12_000, 12_001] {
            let text = String(original.prefix(length))
            let content = Content.text(text)
            let expected = (length > 180 ? String(text.prefix(90)) + "…" + String(text.suffix(90)) : text)
                .replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\t", with: " ")
            try Tests.expect(text.count == length && content.preview == expected, "文本预览边界 \(length)")
            try Tests.expect(content.detail == String(text.prefix(12_000)) + (length > 12_000 ? "\n\n预览已截断，复制保留完整内容。" : ""), "详情截断边界 \(length)")
            try Tests.expect(Entry(id: HistoryStore.fingerprint(.text(text)), date: Date(), content: content).preview == expected, "条目缓存预览")
        }
        let text = Content.text("中文 ClipNest 👨‍👩‍👧‍👦 é")
        let textEntry = Entry(id: "t", date: Date(), content: text)
        if case let .entries(matched, _) = HistorySearch.evaluate([textEntry], query: "中文 clipNEST"),
           case let .entries(unmatched, _) = HistorySearch.evaluate([textEntry], query: "中文 missing") {
            try Tests.expect(matched.map(\.id) == ["t"] && unmatched.isEmpty, "多词与大小写匹配")
        } else { throw AppError("文本搜索应返回记录列表") }
        let family = "👨‍👩‍👧‍👦"
        try Tests.expect(Content.text(String(repeating: family, count: 12_001)).detail.hasPrefix(String(repeating: family, count: 12_000)), "保留完整字符")
        try Tests.rejects("超大内容") { try Payload.text(String(repeating: "x", count: Limits.bytes + 1)).validate() }
        try Tests.rejects("空文本") { try Payload.text("").validate() }
        try Tests.rejects("相对文件路径") { try Payload.files(["relative/path"]).validate() }
        // 数字快捷键纯规则由 ClipNestCoreTests/KeyRoutingTests 覆盖，这里验证 NSEvent 修饰键转换会丢弃大写锁定等无关标志。
        let withCaps = KeyModifiers([.function, .capsLock])
        try Tests.expect(withCaps == .function && withCaps.eventFlags == .function &&
                         HistoryShortcut.fn.index(characters: "9", modifiers: withCaps) == 8, "修饰键桥接保留 Fn 并过滤大写锁定")
    }
}
