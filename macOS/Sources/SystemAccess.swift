import AppKit
import ApplicationServices
import Carbon
import ServiceManagement

enum ClipboardPermission {
    case systemDefault, ask, allowed, denied, notRequired, unknown
}

enum SystemAccess {
    static func clipboardStatus(for board: NSPasteboard = .general) -> ClipboardPermission {
        guard #available(macOS 15.4, *) else { return .notRequired }
        switch board.accessBehavior {
        case .default: return .systemDefault
        case .ask: return .ask
        case .alwaysAllow: return .allowed
        case .alwaysDeny: return .denied
        @unknown default: return .unknown
        }
    }

    static var accessibilityGranted: Bool { AXIsProcessTrusted() }

    static var loginStatus: SMAppService.Status { SMAppService.mainApp.status }

    static func setLoginEnabled(_ enabled: Bool) throws {
        let registered = loginStatus == .enabled || loginStatus == .requiresApproval
        guard enabled != registered else { return }
        if enabled { try SMAppService.mainApp.register() }
        else { try SMAppService.mainApp.unregister() }
    }

    static func openLoginSettings() { SMAppService.openSystemSettingsLoginItems() }

    /// 弹出系统辅助功能授权提示并将应用登记到系统列表，不强行跳转设置窗口。
    static func promptAccessibility() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func requestAccessibility() throws {
        promptAccessibility()
        try openPrivacy(anchor: "Privacy_Accessibility")
    }

    static func openClipboardSettings() throws {
        if #available(macOS 15.4, *) {
            try openPrivacy(anchor: "Privacy_Pasteboard")
        } else {
            try openPrivacy(anchor: nil)
        }
    }

    private static func openPrivacy(anchor: String?) throws {
        let base = "x-apple.systempreferences:com.apple.preference.security"
        if let anchor, let destination = URL(string: base + "?" + anchor), NSWorkspace.shared.open(destination) { return }
        guard let home = URL(string: base), NSWorkspace.shared.open(home) else {
            throw AppError(L("无法打开系统的隐私与安全性设置。"))
        }
    }

    static var isLoginLaunch: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == kAEOpenApplication else { return false }
        // 登录启动事件可直接包含 lgit，或在启动属性参数中携带该枚举值。
        return event.paramDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem)) != nil ||
            event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == keyAELaunchedAsLogInItem
    }
}
