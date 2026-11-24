import AppKit
import Carbon

@MainActor
final class ShortcutRecorder: NSButton {
    var shortcut: OpenShortcut {
        didSet { if !isRecording { title = shortcut.title } }
    }
    var onBegin: (() throws -> Void)?
    var onEnd: (() throws -> Void)?
    var onCommit: ((OpenShortcut) throws -> Void)?
    var onError: ((Error) -> Void)?
    private var monitor: Any?
    var isRecording: Bool { monitor != nil }

    init(shortcut: OpenShortcut) {
        self.shortcut = shortcut
        super.init(frame: .zero)
        title = shortcut.title
        bezelStyle = .rounded
        font = .systemFont(ofSize: 12.5, weight: .medium)
        widthAnchor.constraint(greaterThanOrEqualToConstant: 112).isActive = true
        target = self
        action = #selector(toggleRecording)
        setAccessibilityLabel(L("打开历史面板"))
        setAccessibilityHelp(L("点击后按下新快捷键，按 Esc 取消。"))
    }

    required init?(coder: NSCoder) { fatalError("不支持从归档创建录制控件。") }

    @objc private func toggleRecording() {
        if isRecording { cancelRecording(); return }
        guard let window, window.isKeyWindow else { return }
        do { try onBegin?() }
        catch { onError?(error); return }
        title = L("按下快捷键…")
        contentTintColor = .controlAccentColor
        let types: NSEvent.EventTypeMask = [.keyDown, .flagsChanged, .leftMouseDown, .rightMouseDown, .otherMouseDown]
        monitor = NSEvent.addLocalMonitorForEvents(matching: types) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        guard isRecording else {
            onError?(AppError(L("无法开始录制快捷键。")))
            finish()
            return
        }
        NotificationCenter.default.addObserver(self, selector: #selector(windowLostFocus(_:)),
            name: NSWindow.didResignKeyNotification, object: window)
        NotificationCenter.default.addObserver(self, selector: #selector(windowLostFocus(_:)),
            name: NSWindow.willCloseNotification, object: window)
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window, window === event.window, window.isKeyWindow else {
            cancelRecording()
            return event
        }
        switch event.type {
        case .flagsChanged:
            let modifiers = OpenShortcut.modifierTitle(OpenShortcut.modifierMask(event.modifierFlags))
            title = modifiers.isEmpty ? L("按下快捷键…") : modifiers + "…"
        case .keyDown:
            guard !event.isARepeat else { return nil }
            if Int(event.keyCode) == kVK_Escape { cancelRecording(); return nil }
            let candidate = OpenShortcut(code: Int(event.keyCode), modifiers: OpenShortcut.modifierMask(event.modifierFlags))
            do { try candidate.validateCombination() }
            catch { onError?(error); return nil }
            do {
                try onCommit?(candidate)
                shortcut = candidate
            } catch { onError?(error) }
            finish()
        default:
            if !bounds.contains(convert(event.locationInWindow, from: nil)) { cancelRecording() }
            return event
        }
        return nil
    }

    @objc private func windowLostFocus(_ notification: Notification) { cancelRecording() }

    func cancelRecording() {
        if isRecording { finish() }
    }

    private func finish() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        let center = NotificationCenter.default
        center.removeObserver(self, name: NSWindow.didResignKeyNotification, object: window)
        center.removeObserver(self, name: NSWindow.willCloseNotification, object: window)
        title = shortcut.title
        contentTintColor = nil
        do { try onEnd?() }
        catch { onError?(error) }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        if window !== newWindow { cancelRecording() }
        super.viewWillMove(toWindow: newWindow)
    }
}
