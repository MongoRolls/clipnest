import AppKit

extension PanelTests {
    @MainActor
    struct Driver {
        let window: HistoryWindow
        let table: HistoryTableView
        let content: NSView
        let field: NSSearchField
        let delegate: AppDelegate
        let previousApp: NSRunningApplication?
        private static var launched = false

        static func launch() {
            guard !launched else { return }
            NSApp.setActivationPolicy(.accessory)
            NSApp.finishLaunching()
            launched = true
        }

        init(delegate: AppDelegate, previousApp: NSRunningApplication?) throws {
            try wait(for: "当前原生历史面板获得焦点") { NSApp.isActive && NSApp.keyWindow is HistoryWindow }
            guard let window = NSApp.keyWindow as? HistoryWindow, let content = window.contentView,
                  let field = find(NSSearchField.self, in: content), let table = find(HistoryTableView.self, in: content)
            else { throw AppError("无法获取当前原生历史面板，前台应用：\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "无")。") }
            self.window = window
            self.content = content
            self.table = table
            self.field = field
            self.delegate = delegate
            self.previousApp = previousApp
        }

        static func activate(after previousApp: NSRunningApplication?) throws {
            // 两次独立唤起之间，等上一次关闭面板后的焦点切换完成。
            if let previousApp, previousApp.processIdentifier != getpid(), !previousApp.isTerminated {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier != previousApp.processIdentifier {
                    previousApp.activate(options: [])
                }
                try wait(for: "原应用接回键盘焦点") {
                    !NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == previousApp.processIdentifier
                }
            }
            NSApp.activate(ignoringOtherApps: true)
            try wait(for: "测试进程获得前台键盘焦点") {
                NSApp.isActive && NSWorkspace.shared.frontmostApplication?.processIdentifier == getpid()
            }
        }

        func query(_ value: String) throws {
            window.makeFirstResponder(field)
            guard let editor = field.currentEditor() as? NSTextView else { throw AppError("搜索框未获得编辑焦点。") }
            editor.insertText(value, replacementRange: NSRange(location: 0, length: (editor.string as NSString).length))
        }
        func press(_ code: UInt16, _ characters: String, flags: NSEvent.ModifierFlags = [], throughApp: Bool = false) throws {
            guard let target = throughApp ? NSApp.keyWindow : window, !throughApp || NSApp.isActive else {
                throw AppError("测试应用失去键盘焦点，前台应用：\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "无")。")
            }
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: target.windowNumber, context: nil,
                characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
            else { throw AppError("无法创建键盘事件。") }
            if throughApp { NSApp.sendEvent(event) } else { window.sendEvent(event) }
        }
        func openForSearch() throws {
            if !NSApp.isActive || !window.isKeyWindow {
                try Self.activate(after: previousApp)
                delegate.showWindow(nil)
            }
            try wait(for: "面板可搜索") { window.isKeyWindow && table.isEnabled }
        }

        func click(_ view: NSView, at point: NSPoint) throws {
            let location = view.convert(point, to: nil)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                    eventNumber: 1, clickCount: 1, pressure: 1) else { throw AppError("无法创建点击事件。") }
                NSApp.postEvent(event, atStart: false)
            }
        }

        func pointerEvent(_ type: NSEvent.EventType, row: Int) throws -> NSEvent {
            let rect = table.rect(ofRow: row)
            let location = table.convert(NSPoint(x: rect.midX, y: rect.midY), to: nil)
            guard let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil,
                eventNumber: 1, clickCount: 1, pressure: 0) else { throw AppError("无法创建图片行的鼠标事件。") }
            return event
        }
    }
}
