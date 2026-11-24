import AppKit
import Carbon

extension PanelTests {
    private static func checkSettingsAppearance(_ window: NSWindow, controller: SettingsWindowController) throws {
        let original = window.appearance
        let initialPane = controller.selectedPane
        defer { window.appearance = original; controller.selectPane(initialPane, recordHistory: false) }
        func controls(in view: NSView) -> [NSView] {
            guard !view.isHiddenOrHasHiddenAncestor else { return [] }
            if let label = view as? NSTextField, label.stringValue.isEmpty { return [] }
            if view is NSControl { return [view] }
            return view.subviews.flatMap(controls(in:))
        }
        for appearance in [NSAppearance.Name.aqua, .darkAqua] {
            window.appearance = NSAppearance(named: appearance)
            for pane in SettingsPane.allCases {
                controller.selectPane(pane, recordHistory: false)
                guard let pageView = controller.currentPageView else { throw AppError("未找到设置页。") }
                try wait(for: "\(pane.title)分页布局") {
                    window.contentView?.layoutSubtreeIfNeeded()
                    return pageView.window === window
                }
                try Tests.expect(pageView.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == appearance,
                    "\(pane.title)使用指定外观")
                let document = (pageView as? NSScrollView)?.documentView ?? pageView
                let items = controls(in: document)
                try Tests.expect(!items.isEmpty, "\(pane.title)显示设置控件")
                var frames = [NSRect]()
                for control in items {
                    let frame = control.convert(control.bounds, to: document)
                    let inner = frame.insetBy(dx: 1, dy: 1)
                    let name = control.accessibilityLabel() ?? String(describing: type(of: control))
                    try Tests.expect(!inner.isEmpty && document.bounds.insetBy(dx: -1, dy: -1).contains(inner),
                                     "\(pane.title)的\(name)超出可用区域：\(frame)，\(document.bounds)")
                    try Tests.expect(!frames.contains { $0.intersects(inner) }, "\(pane.title)的\(name)与其他控件重叠")
                    frames.append(inner)
                }
            }
        }
        print("PASS 原生设置窗口在浅色与深色外观下的五个分页布局")
    }

    static func checkSettingsAndShortcuts(driver: Driver, preferences: AppSettings, defaults: UserDefaults,
                                          board: NSPasteboard, url: URL, directory: URL, views: String,
                                          app: String, previousApp: NSRunningApplication?) throws {
        let delegate = driver.delegate, window = driver.window, table = driver.table, content = driver.content
        let menuIndex = delegate.statusMenu.indexOfItem(withTitle: "设置…")
        try Tests.expect(menuIndex >= 0, "菜单栏右键菜单提供设置入口")
        delegate.statusMenu.performActionForItem(at: menuIndex)
        try wait(for: "设置窗口获得焦点") { NSApp.keyWindow?.title == "ClipNest 设置" && !window.isVisible }
        guard let settingsWindow = NSApp.keyWindow,
              let controller = settingsWindow.windowController as? SettingsWindowController,
              let generalView = controller.currentPageView
        else { throw AppError("无法取得通用设置页。") }
        defer { settingsWindow.close() }
        try Tests.expect(controller.selectedPane == .general &&
            SettingsPane.allCases.map(\.title) == ["通用", "快捷键", "历史", "权限", "关于"], "设置窗口提供五个分页")
        try checkSettingsAppearance(settingsWindow, controller: controller)
        for pane in [SettingsPane.history, .permissions, .history] {
            controller.selectPane(pane)
        }
        guard let historyPage = controller.currentPageView,
              let diskSize = find(NSTextField.self, in: historyPage, matching: { $0.accessibilityLabel() == "数据库占用大小" }),
              let historyLimit = find(NSPopUpButton.self, in: historyPage, matching: { $0.accessibilityLabel() == "保留条数" }),
              let bytes = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            throw AppError("缺少历史设置的数据库大小或保留条数。")
        }
        let expectedSize = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        try wait(for: "快速切换分页后读回实际数据库大小") { diskSize.stringValue == expectedSize }
        try Tests.expect(historyLimit.itemTitles == AppSettings.historyLimits.map { L("%d 条", $0) }, "重复打开历史页保留每个选项一份")
        controller.selectPane(.general)
        guard let appearancePicker = find(NSPopUpButton.self, in: generalView, matching: { $0.accessibilityLabel() == "面板外观" }) else {
            throw AppError("未找到面板外观选项。")
        }
        for appearance in [PanelAppearance.dark, .light, .system] {
            appearancePicker.selectItem(withTitle: appearance.title)
            _ = appearancePicker.sendAction(appearancePicker.action, to: appearancePicker.target)
            try Tests.expect(preferences.appearance == appearance && window.appearance?.name == appearance.nsAppearance?.name,
                             "保存外观并立即更新已创建的面板")
        }
        guard let intensity = find(NSSlider.self, in: generalView, matching: { $0.accessibilityLabel() == "图片不透明度" }),
              let remove = find(NSButton.self, in: generalView, matching: { $0.title == "移除" }) else {
            throw AppError("未找到背景图片设置。")
        }
        try Tests.expect(!intensity.isHiddenOrHasHiddenAncestor && intensity.integerValue == 8, "背景图默认不透明度为 8%")
        for value in [5, 30, 8] {
            intensity.integerValue = value
            _ = intensity.sendAction(intensity.action, to: intensity.target)
            try Tests.expect(preferences.backgroundIntensity == value &&
                intensity.accessibilityValueDescription() == "\(value)%", "调整图片不透明度后显示对应百分比")
        }
        remove.performClick(nil)
        try Tests.expect(intensity.isHiddenOrHasHiddenAncestor &&
            PanelBackgroundStore(directory: directory).image == nil, "通用设置移除面板背景")
        try Tests.expect(controller.selectedPane == .general &&
                         find(NSPopUpButton.self, in: generalView) { $0.accessibilityLabel() == "窗口显示位置" } == nil &&
                         find(NSPopUpButton.self, in: content) == nil, "通用设置和面板均已移除位置选择器")
        controller.selectPane(.keyboard)
        guard let keyView = controller.currentPageView,
              let recorder = find(ShortcutRecorder.self, in: keyView, matching: { $0.accessibilityLabel() == "打开历史面板" }),
              let confirm = find(NSPopUpButton.self, in: keyView, matching: { $0.accessibilityLabel() == "确认复制" }),
              let number = find(NSPopUpButton.self, in: keyView, matching: { $0.accessibilityLabel() == "数字选取" })
        else { throw AppError("无法取得按键设置控件。") }
        func recordKey(_ code: Int, _ characters: String, flags: NSEvent.ModifierFlags) throws {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: settingsWindow.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: UInt16(code))
            else { throw AppError("无法创建录制按键事件。") }
            NSApp.postEvent(event, atStart: true)
        }
        func beginRecording() throws {
            recorder.performClick(nil)
            try Tests.expect(recorder.isRecording, "按下录制按钮开始接收按键")
        }
        try beginRecording()
        try recordKey(kVK_ANSI_K, "k", flags: .shift)
        try wait(for: "仅 Shift 时继续录制并记录诊断") {
            let log = try? String(contentsOf: directory.appendingPathComponent("errors.log"), encoding: .utf8)
            return recorder.isRecording && log?.contains("注册快捷键") == true
        }
        try recordKey(kVK_Escape, "\u{1b}", flags: [])
        try wait(for: "Esc 取消录制") { !recorder.isRecording }
        try beginRecording()
        try recordKey(kVK_ANSI_Q, "q", flags: .command)
        try wait(for: "拦截退出快捷键并恢复原组合") {
            !recorder.isRecording && settingsWindow.isKeyWindow && recorder.shortcut == KeyboardSettings().open
        }
        let shortcut = OpenShortcut(code: kVK_ANSI_K, modifiers: cmdKey | optionKey | shiftKey)
        try beginRecording()
        try recordKey(shortcut.code, "k", flags: [.command, .option, .shift])
        try wait(for: "提交录制组合") { !recorder.isRecording && recorder.shortcut == shortcut }
        try beginRecording()
        try recordKey(shortcut.code, "k", flags: [.command, .option, .shift])
        try wait(for: "再次录入当前组合") { !recorder.isRecording && recorder.shortcut == shortcut }
        confirm.selectItem(withTitle: ConfirmationKey.commandEnter.title)
        _ = confirm.sendAction(confirm.action, to: confirm.target)
        number.selectItem(withTitle: "⌃ + 1–9")
        _ = number.sendAction(number.action, to: number.target)
        let saved = try AppSettings.readKeyboard(from: defaults)
        try Tests.expect(saved == KeyboardSettings(open: shortcut, confirm: .commandEnter, number: .control),
            "保存新按键并读回")
        var occupied: EventHotKeyRef?
        let status = RegisterEventHotKey(UInt32(kVK_ANSI_J), UInt32(shortcut.modifiers), EventHotKeyID(signature: 0x54455354, id: 1),
            GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &occupied)
        guard status == noErr, let occupied else { throw AppError("无法注册测试占用的组合键（\(status)）。") }
        defer { UnregisterEventHotKey(occupied) }
        try beginRecording()
        try recordKey(kVK_ANSI_J, "j", flags: [.command, .option, .shift])
        try wait(for: "注册冲突后结束录制") { !recorder.isRecording }
        let afterConflict = try AppSettings.readKeyboard(from: defaults)
        try Tests.expect(afterConflict == saved && recorder.shortcut == shortcut && settingsWindow.attachedSheet == nil &&
            find(NSTextField.self, in: keyView) { $0.stringValue.contains("注册失败") } == nil, "注册冲突保留原设置且不显示错误")
        if CGPreflightPostEventAccess() {
            for down in [true, false] {
                guard let event = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(shortcut.code), keyDown: down)
                else { throw AppError("无法发送已注册的面板快捷键。") }
                event.flags = [.maskCommand, .maskAlternate, .maskShift]
                event.post(tap: .cghidEventTap)
            }
            try wait(for: "修改后的全局快捷键打开面板") { window.isKeyWindow }
            print("PASS 系统分派自定义全局快捷键，注册冲突后原组合仍可唤起")
        } else {
            print("未验证系统按键分派：测试进程缺少发送系统按键的权限。")
            delegate.showWindow(nil)
        }
        try driver.query("NSGlassEffectView cornerRadius")
        try wait(for: "自定义确认键测试的搜索结果") { table.isEnabled && table.numberOfRows == 1 }
        try driver.press(36, "\r")
        try Tests.expect(window.isVisible, "切换确认键后单按回车保留面板")
        try driver.press(36, "\r", flags: .command)
        try wait(for: "自定义确认键复制") { !window.isVisible && board.string(forType: .string) == views }
        try Driver.activate(after: previousApp)
        delegate.showWindow(nil)
        try wait(for: "自定义数字快捷键测试就绪") { window.isKeyWindow && table.isEnabled }
        try driver.query("statusClick registerHotkey")
        try driver.press(18, "1", flags: .control)
        try wait(for: "自定义数字选取复制") { !window.isVisible && board.string(forType: .string) == app }
        print("PASS 精简标题、设置标签页、按键持久化及自定义复制操作")
    }
}
