import AppKit
import Carbon

@MainActor
enum Paster {
    /// 除逻辑 Command 标志外附带左 Command 设备位，兼容检查设备修饰位的 Electron 与跨平台应用。
    static let commandFlags = CGEventFlags(rawValue: CGEventFlags.maskCommand.rawValue | 0x000008)
    /// 原应用刚回到前台时，留出短暂窗口让目标窗口与输入控件完成焦点交接。
    static let focusSettleDelay: TimeInterval = 0.05

    /// 当前布局中 "v" 所在的物理键码；读取布局失败时退回 ANSI 键位。
    static func pasteKeyCode() -> CGKeyCode {
        CGKeyCode(KeyboardLayout.keyCode(for: "v") ?? kVK_ANSI_V)
    }

    @discardableResult
    static func activate(_ app: NSRunningApplication) -> Bool {
        guard !app.isTerminated, app.processIdentifier != getpid() else { return false }
        if #available(macOS 14.0, *) { NSApp.yieldActivation(to: app) }
        return app.activate(options: [])
    }

    /// 构造带独立抑制间隔的 ⌘V 合成按键事件，避免按下 Shift/Enter 时的残余物理按键串扰粘贴。
    static func makePasteEvents(key: CGKeyCode? = nil) -> (down: CGEvent, up: CGEvent)? {
        let key = key ?? pasteKeyCode()
        let source = CGEventSource(stateID: .combinedSessionState)
        source?.localEventsSuppressionInterval = focusSettleDelay
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval)
        guard let down = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: key, keyDown: false) else {
            return nil
        }
        down.flags = commandFlags
        up.flags = commandFlags
        return (down, up)
    }

    static func paste(to app: NSRunningApplication, isCurrent: @escaping () -> Bool,
                      ownsClipboard: @escaping () -> Bool, onError: @escaping (Error) -> Void) {
        guard activate(app) else {
            onError(AppError(L("无法激活原应用，内容已复制。"), code: .directPaste))
            return
        }
        let deadline = ProcessInfo.processInfo.systemUptime + 1
        func deliver() {
            guard isCurrent() else { return }
            guard !app.isTerminated, NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else {
                onError(AppError(L("原应用未回到前台，已取消直接粘贴。"), code: .directPaste))
                return
            }
            guard SystemAccess.accessibilityGranted else {
                onError(AppError(L("辅助功能权限已关闭，内容已复制。"), code: .directPaste))
                return
            }
            guard ownsClipboard() else {
                onError(AppError(L("剪贴板已更新，已取消直接粘贴。"), code: .directPaste))
                return
            }
            guard let events = makePasteEvents() else {
                onError(AppError(L("无法创建粘贴按键事件，内容已复制。"), code: .directPaste))
                return
            }
            // 通过会话事件流投递给已核对的前台应用，避免 postToPid 在 Chromium/Electron 等多进程应用里被丢弃。
            events.down.post(tap: .cgSessionEventTap)
            events.up.post(tap: .cgSessionEventTap)
        }
        // 激活请求异步完成。仅在本次面板操作仍有效且原应用已回到前台时投递一次。
        func sendWhenActive() {
            guard isCurrent() else { return }
            let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
            if !app.isTerminated, front == app.processIdentifier {
                DispatchQueue.main.asyncAfter(deadline: .now() + focusSettleDelay) { deliver() }
            } else if !app.isTerminated, front == nil || front == getpid(), ProcessInfo.processInfo.systemUptime < deadline {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.025) { sendWhenActive() }
            } else {
                onError(AppError(L("原应用未回到前台，已取消直接粘贴。"), code: .directPaste))
            }
        }
        sendWhenActive()
    }
}
