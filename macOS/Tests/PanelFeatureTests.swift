import AppKit
import Carbon
import CryptoKit

extension PanelTests {
    static func panelBackground(_ directory: URL) throws {
        let store = PanelBackgroundStore(directory: directory)
        try Tests.expect(store.image == nil && store.loadError == nil, "新安装默认使用系统材质")
        let source = directory.appendingPathComponent("initial-background.png")
        try FileManager.default.copyItem(at: TestProject.icon, to: source)
        try importBackground(source, into: store)
        guard let image = store.image else { throw AppError("导入后没有背景图。") }
        try FileManager.default.removeItem(at: source)
        try Tests.rejects("导入已移走的原图") { try importBackground(source, into: store) }
        try Tests.rejects("导入非图片文件") { try importBackground(TestProject.root.appendingPathComponent("README.md"), into: store) }
        let restored = PanelBackgroundStore(directory: directory)
        try Tests.expect(store.image === image && restored.name == source.lastPathComponent &&
            restored.image?.size == image.size && restored.loadError == nil, "导入失败和移动原图后，重启仍可读取之前的背景")
        let replacement = TestProject.icon
        try importBackground(replacement, into: restored)
        try Tests.expect(PanelBackgroundStore(directory: directory).name == replacement.lastPathComponent, "更换图片后持久化新文件名")
        try restored.remove()
        let cleared = PanelBackgroundStore(directory: directory)
        try Tests.expect(cleared.image == nil && cleared.loadError == nil, "移除后重启恢复系统材质")
    }

    static func localizedLoadFailure(_ directory: URL) throws {
        let url = directory.appendingPathComponent("history.db")
        let originalKey = SymmetricKey(size: .bits256)
        let input = try TestProject.source("Models")
        let entry = try HistoryStore(url: url, key: originalKey).save(.text(input))
        let board = NSPasteboard(name: .init("com.clipnest.load-failure.\(UUID().uuidString)"))
        defer { board.releaseGlobally(); L10n.select(.system) }
        var errors: [String] = []
        let service = HistoryService(clipboard: ClipboardAccess(board), recoveryURL: url) { action, error in
            errors.append(action + " " + error.localizedDescription)
        }
        defer { service.invalidatePolling() }
        let resources = TestProject.resources
        let wrongKey = SymmetricKey(size: .bits256)
        L10n.select(.simplifiedChinese, resources: resources)
        service.start { try HistoryStore(url: url, key: wrongKey) }
        try wait(for: "第一次用错误密钥打开数据库") { errors.count == 1 }
        try Tests.expect(!service.ready && errors[0].contains("请检查密钥或数据库"), "实际开库失败原因可见")
        L10n.select(.english, resources: resources)
        service.reloadLocalizedSnapshot()
        try wait(for: "以当前语言重新获得数据库诊断") { errors.count == 2 }
        try Tests.expect(!service.ready && errors[1].contains("encryption key") && !errors[1].contains("密钥"), "持久故障显示英语原因")
        try Tests.expect(try HistoryStore(url: url, key: originalKey).payload(for: entry.id) == .text(input), "重新检查故障保留原密文")
        try checkRecoveryPanel(service, url: url, originalKey: originalKey, entry: entry, originalText: input)
    }

    private static func checkRecoveryPanel(_ service: HistoryService, url: URL, originalKey: SymmetricKey,
                                           entry: Entry, originalText: String) throws {
        let previous = NSWorkspace.shared.frontmostApplication
        defer { if NSApp.isActive, previous?.processIdentifier != getpid() { previous?.activate(options: []) } }
        Driver.launch()
        try Driver.activate(after: previous)
        let suite = "com.clipnest.recovery.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw AppError("无法建立恢复测试偏好。") }
        defer { defaults.removePersistentDomain(forName: suite) }
        let panel = HistoryPanelController(service: service, settings: AppSettings(defaults: defaults))
        panel.showWindow(nil)
        defer { panel.hide() }
        try wait(for: "恢复面板显示") { NSApp.keyWindow is HistoryWindow }
        guard let window = NSApp.keyWindow, let root = window.contentView,
              let archive = find(NSButton.self, in: root, matching: { $0.title == L("归档旧库并重新开始…") }),
              let retry = find(NSButton.self, in: root, matching: { $0.title == L("重新加载") }),
              let log = find(NSButton.self, in: root, matching: { $0.title == L("打开错误日志") }) else {
            throw AppError("缺少恢复操作。")
        }
        try Tests.expect(archive.isEnabled && retry.isEnabled && !archive.isHiddenOrHasHiddenAncestor &&
                         log.target === panel && log.action != nil &&
                         find(NSTextView.self, in: root) { !$0.isHiddenOrHasHiddenAncestor && $0.string.contains("encryption key") } != nil,
                         "显示实际故障及恢复与日志入口")
        retry.performClick(nil)
        try wait(for: "重试后重新显示故障") { service.loadFailure != nil && service.canArchiveAfterFailure && archive.isEnabled }
        func archiveDirectories() throws -> [URL] {
            try FileManager.default.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: [.isDirectoryKey])
                .filter { item in
                    guard item.lastPathComponent.hasPrefix("history.corrupt-") else { return false }
                    return try item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
                }
        }
        let originalBytes = try Data(contentsOf: url)
        for (title, cancelling) in [(L("取消"), true), (L("归档并重新开始"), false)] {
            archive.performClick(nil)
            try wait(for: "显示归档确认") { window.attachedSheet != nil }
            guard let sheet = window.attachedSheet?.contentView, let button = find(NSButton.self, in: sheet, matching: { $0.title == title })
            else { throw AppError("无法读取确认按钮。") }
            try Tests.expect(try HistoryStore(url: url, key: originalKey).payload(for: entry.id) == .text(originalText),
                             "确认前原数据库可完整解密")
            button.performClick(nil)
            try wait(for: "关闭归档确认") { window.attachedSheet == nil }
            if cancelling {
                try Tests.expect(try archiveDirectories().isEmpty && Data(contentsOf: url) == originalBytes,
                                 "取消后原库字节不变，也未创建归档目录")
            }
        }
        try wait(for: "明确确认后重开空历史") { service.isIdle && service.entries.isEmpty && archive.isHiddenOrHasHiddenAncestor }
        let directories = try archiveDirectories()
        guard directories.count == 1, let archiveDirectory = directories.first else { throw AppError("确认后应有一个归档目录。") }
        let backup = archiveDirectory.appendingPathComponent(archiveDirectory.lastPathComponent + ".db")
        try Tests.expect(try Data(contentsOf: backup) == originalBytes &&
                         HistoryStore(url: backup, key: originalKey).payload(for: entry.id) == .text(originalText),
                         "归档数据库逐字节一致且仍可用原密钥解密")
    }

    static func shortcutRules(_ directory: URL) throws {
        // 完整校验矩阵由 ClipNestCoreTests/KeyRoutingTests 覆盖，这里验证真实系统键盘布局桥接。
        try Tests.expect(OpenShortcut.keyTitle(kVK_Space) == L("空格") && OpenShortcut.keyTitle(kVK_F1) == "F1", "系统布局下特殊键名称")
        try KeyboardSettings().validate()
        try KeyboardSettings(open: OpenShortcut(code: kVK_ANSI_T, modifiers: cmdKey)).validate()
        for (code, modifiers) in [(kVK_ANSI_Q, cmdKey), (kVK_ANSI_2, controlKey)] {
            try Tests.rejects("拒绝系统布局下冲突的快捷键") {
                try KeyboardSettings(open: OpenShortcut(code: code, modifiers: modifiers), number: .control).validate()
            }
        }
    }

    static func commands(_ directory: URL) throws {
        for command in PanelCommand.allCases {
            try Tests.expect(PanelCommand.matching(command.rawValue, paused: false, directPaste: false).first == command,
                             "输入命令全名时优先选中 \(command.rawValue)")
        }
        try Tests.expect(PanelCommand.matching("收藏", paused: false, directPaste: false).first == .favorites &&
                         PanelCommand.matching("pref", paused: false, directPaste: false).first == .settings &&
                         PanelCommand.matching("plain", paused: false, directPaste: false).first == .plainText,
                         "按中英文别名查找命令")
        for removed in ["pos center", "pos cursor", "pos status", "居中", "鼠标附近", "菜单栏旁"] {
            try Tests.expect(PanelCommand.matching(removed, paused: false, directPaste: false).isEmpty, "不再提供位置命令 \(removed)")
        }
        try Tests.expect(PanelCommand.pause.title(paused: true, directPaste: false) != PanelCommand.pause.title(paused: false, directPaste: false) &&
                         PanelCommand.paste.title(paused: false, directPaste: true) != PanelCommand.paste.title(paused: false, directPaste: false) &&
                         PanelCommand.plainText.title(paused: false, directPaste: false, plainText: true) != PanelCommand.plainText.title(paused: false, directPaste: false, plainText: false),
                         "暂停、粘贴和纯文本命令展示当前可执行操作")
    }

    static func directPasteAndAccessibility(_ directory: URL) throws {
        guard let events = Paster.makePasteEvents() else {
            throw AppError("无法构造 ⌘V 粘贴按键事件。")
        }
        let expectedKey = Int64(Paster.pasteKeyCode())
        try Tests.expect(events.down.type == .keyDown && events.up.type == .keyUp &&
                         events.down.getIntegerValueField(.keyboardEventKeycode) == expectedKey &&
                         events.up.getIntegerValueField(.keyboardEventKeycode) == expectedKey &&
                         events.down.flags == Paster.commandFlags && events.up.flags == Paster.commandFlags &&
                         Paster.commandFlags.contains(.maskCommand) && (Paster.commandFlags.rawValue & 0x000008) != 0,
                         "构造带左 Command 设备位与当前布局键码的 ⌘V 粘贴事件")

        let board = NSPasteboard(name: .init("com.clipnest.direct-paste.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let url = directory.appendingPathComponent("history.db")
        let key = SymmetricKey(size: .bits256)
        let db = try HistoryStore(url: url, key: key)
        _ = try db.save(.text("first-entry"))
        _ = try db.save(.text("second-entry"))

        let service = HistoryService(clipboard: ClipboardAccess(board)) { _, _ in }
        defer { service.invalidatePolling() }
        service.start { try HistoryStore(url: url, key: key) }
        try wait(for: "加载直接粘贴测试历史") { service.isIdle && service.entries.count == 2 }

        let suite = "com.clipnest.direct-paste.\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else { throw AppError("无法建立直接粘贴测试偏好。") }
        defer { defaults.removePersistentDomain(forName: suite); L10n.select(.system) }
        L10n.select(.simplifiedChinese, resources: TestProject.resources)
        let settings = AppSettings(defaults: defaults)
        try Tests.expect(settings.directPaste, "新偏好默认开启直接粘贴")

        let panel = HistoryPanelController(service: service, settings: settings)
        defer { panel.hide() }
        var granted = false
        var promptCount = 0
        var activatedCount = 0
        var pastedTargets: [pid_t] = []
        panel.actions.isAccessibilityGranted = { granted }
        panel.actions.onPromptAccessibility = { promptCount += 1 }
        panel.actions.onActivate = { _ in activatedCount += 1 }
        panel.actions.onPaste = { target, _, _, _ in pastedTargets.append(target.processIdentifier) }

        guard let target = NSWorkspace.shared.frontmostApplication.flatMap({ $0.processIdentifier == getpid() ? nil : $0 })
                ?? NSWorkspace.shared.runningApplications.first(where: { $0.processIdentifier != getpid() && !$0.isTerminated && $0.activationPolicy == .regular }) else {
            throw AppError("未找到可用的外部应用作为直接粘贴目标。")
        }

        // 单元测试使用隔离剪贴板时默认只激活目标应用，不误触发系统粘贴或权限弹窗。
        let isolatedOutcome = panel.actions.returnToTarget(target, version: board.changeCount, directPaste: true,
                                                           isCurrent: { true }, report: { _ in })
        try Tests.expect(isolatedOutcome == .activated && activatedCount == 1 && promptCount == 0 && pastedTargets.isEmpty,
                         "隔离剪贴板默认不触发系统粘贴")

        panel.actions.allowTestDirectPaste = true
        try Tests.expect(panel.actions.returnToTarget(nil, version: board.changeCount, directPaste: true,
                                                      isCurrent: { true }, report: { _ in }) == .none,
                         "无原应用时跳过直接粘贴")
        try Tests.expect(panel.actions.returnToTarget(target, version: board.changeCount, directPaste: false,
                                                      isCurrent: { true }, report: { _ in }) == .activated && activatedCount == 2,
                         "关闭直接粘贴时仅切回原应用")

        // 端到端验证：打开面板 → 方向键切换到第二条 → 按回车复制并触发直接粘贴/权限引导。
        let previous = NSWorkspace.shared.frontmostApplication
        defer { if NSApp.isActive, previous?.processIdentifier != getpid() { previous?.activate(options: []) } }
        Driver.launch()
        func sendKey(_ code: UInt16, _ chars: String) throws {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.window.windowNumber, context: nil,
                characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)
            else { throw AppError("无法创建键盘事件。") }
            panel.window.sendEvent(event)
        }
        func openPanel(expectBanner: Bool) throws {
            if let previous, previous.processIdentifier != getpid(), !previous.isTerminated {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier != previous.processIdentifier || NSApp.isActive {
                    previous.activate(options: [])
                }
                try wait(for: "外部应用接回焦点") {
                    !NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == previous.processIdentifier
                }
            }
            panel.showWindow(nil)
            try wait(for: "打开直接粘贴测试面板") {
                NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid() &&
                    panel.window.isKeyWindow && panel.table.isEnabled && panel.table.numberOfRows == 2 &&
                    panel.view.accessibilityBanner.isHidden != expectBanner
            }
        }

        // 切走失活时面板应主动 orderOut，避免以旧坐标滞留；已隐藏状态下失活不得作废直接粘贴票据。
        try openPanel(expectBanner: false)
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        try Tests.expect(!panel.window.isVisible, "应用失活时面板主动 orderOut 而非滞留隐藏态")
        let ticketAfterHide = panel.presentation.ticket
        NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: NSApp)
        try Tests.expect(panel.presentation.isCurrent(ticketAfterHide), "面板已隐藏后再次收到失活通知不作废直接粘贴票据")

        try openPanel(expectBanner: false)
        try sendKey(UInt16(kVK_DownArrow), "\u{F701}")
        try Tests.expect(panel.table.selectedRow == 1, "方向键切换到第二条记录")
        try sendKey(UInt16(kVK_Return), "\r")
        try wait(for: "缺权限按回车复制并关闭面板") { !panel.window.isVisible && board.string(forType: .string) == "first-entry" }
        try Tests.expect(panel.previousApp != nil && promptCount == 1 && pastedTargets.isEmpty && panel.accessibilityHintNeeded,
                         "首次缺权限尝试直接粘贴时弹出一次授权引导并记录横幅提示")

        // 再次打开面板时显示辅助功能横幅，再次按回车不重复弹出系统授权对话框。
        try openPanel(expectBanner: true)
        try Tests.expect(panel.window.minSize.height > HistoryLayout.minimumHeight, "展示辅助功能横幅时同步增加最小高度")
        try sendKey(UInt16(kVK_DownArrow), "\u{F701}")
        try sendKey(UInt16(kVK_Return), "\r")
        try wait(for: "第二次缺权限按回车复制并关闭") { !panel.window.isVisible && board.string(forType: .string) == "second-entry" }
        try Tests.expect(promptCount == 1 && pastedTargets.isEmpty, "同一运行期缺权限时不重复弹出系统授权提示")

        // 关闭直接粘贴后立即收起辅助功能横幅；授予权限后打开面板不显示横幅并直接触发粘贴。
        try openPanel(expectBanner: true)
        settings.directPaste = false
        panel.updateAccessibilityBanner()
        try Tests.expect(panel.view.accessibilityBanner.isHidden && !panel.accessibilityHintNeeded, "关闭直接粘贴后立即隐藏辅助功能横幅")

        settings.directPaste = true
        granted = true
        panel.hide()
        try openPanel(expectBanner: false)
        try sendKey(UInt16(kVK_DownArrow), "\u{F701}")
        try sendKey(UInt16(kVK_Return), "\r")
        try wait(for: "授权后方向键切换并回车直接粘贴输出") {
            !panel.window.isVisible && board.string(forType: .string) == "first-entry" && pastedTargets.count == 1
        }
        try Tests.expect(pastedTargets == [panel.previousApp!.processIdentifier], "向原应用投递直接粘贴")
    }
}
