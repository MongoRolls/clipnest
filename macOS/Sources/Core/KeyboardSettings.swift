import Carbon
import Foundation

// 本文件的类型经 PropertyListEncoder 保存为已发布的 `keyboardSettings` 偏好：
// 存储属性名、枚举原始值和 Carbon 键码/修饰键掩码都不得改变。
// 当前键盘布局由界面层以 `layout` 闭包传入，核心逻辑保持无窗口可测。

package enum ConfirmationKey: String, CaseIterable, Codable {
    case enter, commandEnter, optionEnter, tab

    package var title: String {
        switch self {
        case .enter: return L("回车")
        case .commandEnter: return L("⌘ 回车")
        case .optionEnter: return L("⌥ 回车")
        case .tab: return "Tab"
        }
    }
    package var keyModifiers: KeyModifiers {
        switch self {
        case .commandEnter: return .command
        case .optionEnter: return .option
        default: return []
        }
    }
    package var keyEquivalent: String { self == .tab ? "\t" : "\r" }

    package func matches(code: Int, modifiers: KeyModifiers) -> Bool {
        guard self == .tab ? code == kVK_Tab : (code == kVK_Return || code == kVK_ANSI_KeypadEnter) else { return false }
        var modifiers = modifiers
        if code == kVK_ANSI_KeypadEnter { modifiers.remove(.function) }
        return modifiers == keyModifiers || modifiers == keyModifiers.union(.shift)
    }
}

package struct OpenShortcut: Codable, Equatable {
    package var code = kVK_ANSI_V
    package var modifiers = cmdKey | shiftKey

    package init(code: Int = kVK_ANSI_V, modifiers: Int = cmdKey | shiftKey) {
        self.code = code
        self.modifiers = modifiers
    }

    private static let functionKeys = [kVK_F1, kVK_F2, kVK_F3, kVK_F4, kVK_F5, kVK_F6, kVK_F7, kVK_F8,
        kVK_F9, kVK_F10, kVK_F11, kVK_F12, kVK_F13, kVK_F14, kVK_F15, kVK_F16, kVK_F17, kVK_F18, kVK_F19, kVK_F20]
    private static let modifierKeys = [kVK_Command, kVK_RightCommand, kVK_Option, kVK_RightOption, kVK_Control,
        kVK_RightControl, kVK_Shift, kVK_RightShift, kVK_CapsLock, kVK_Function]

    package static func modifierMask(_ modifiers: KeyModifiers) -> Int {
        (modifiers.contains(.control) ? controlKey : 0) | (modifiers.contains(.option) ? optionKey : 0)
            | (modifiers.contains(.shift) ? shiftKey : 0) | (modifiers.contains(.command) ? cmdKey : 0)
    }

    package func validateCombination() throws {
        guard UInt16(exactly: code) != nil, !Self.modifierKeys.contains(code), code != kVK_Escape,
              modifiers & ~(cmdKey | optionKey | controlKey | shiftKey) == 0 else {
            throw AppError(L("请选择有效的面板快捷键。"))
        }
        guard modifiers & (cmdKey | optionKey | controlKey) != 0 || (modifiers == 0 && Self.functionKeys.contains(code)) else {
            throw AppError(L("请同时按住 ⌘、⌥ 或 ⌃，也可以单独使用 F1–F20。"))
        }
    }

    package static func modifierTitle(_ mask: Int) -> String {
        [(controlKey, "⌃"), (optionKey, "⌥"), (shiftKey, "⇧"), (cmdKey, "⌘")]
            .filter { mask & $0.0 != 0 }.map(\.1).joined()
    }
    /// `layout` 返回物理键在当前键盘布局下的字符，无法换算时返回 nil。
    package static func keyTitle(_ code: Int, layout: (Int) -> String?) -> String {
        if let index = functionKeys.firstIndex(of: code) { return "F\(index + 1)" }
        switch code {
        case kVK_Space: return L("空格")
        case kVK_Return: return L("回车")
        case kVK_ANSI_KeypadEnter: return "⌤"
        case kVK_LeftArrow: return "←"
        case kVK_RightArrow: return "→"
        case kVK_UpArrow: return "↑"
        case kVK_DownArrow: return "↓"
        case kVK_Tab: return "Tab"
        case kVK_Escape: return "Esc"
        case kVK_Delete: return "⌫"
        case kVK_ForwardDelete: return "⌦"
        case kVK_Home: return "↖"
        case kVK_End: return "↘"
        case kVK_PageUp: return "⇞"
        case kVK_PageDown: return "⇟"
        case kVK_Help: return "Help"
        default: break
        }
        // Carbon 按物理键位注册，菜单标签按当前键盘布局显示。
        if let characters = layout(code) { return characters.uppercased() }
        return L("键码 %ld", code)
    }
    package func displayTitle(layout: (Int) -> String?) -> String {
        Self.modifierTitle(modifiers) + Self.keyTitle(code, layout: layout)
    }
    package var eventID: UInt32 { UInt32(modifiers) << 16 | UInt32(code) }
}

package struct KeyboardSettings: Codable, Equatable {
    package var open = OpenShortcut()
    package var confirm = ConfirmationKey.enter
    package var number = HistoryShortcut.fn

    package init(open: OpenShortcut = OpenShortcut(), confirm: ConfirmationKey = .enter, number: HistoryShortcut = .fn) {
        self.open = open
        self.confirm = confirm
        self.number = number
    }

    /// 拒绝与数字选取、编辑命令、面板快捷键或确认键冲突的打开组合。
    /// 字母和数字键按当前布局换算后比较，与菜单显示保持一致。
    package func validate(layout: (Int) -> String?) throws {
        try open.validateCombination()
        let key = OpenShortcut.keyTitle(open.code, layout: layout)
        let numberModifiers: [HistoryShortcut: Int] = [.command: cmdKey, .option: optionKey, .control: controlKey]
        if numberModifiers[number] == open.modifiers, let digit = Int(key), HistoryShortcut.numbers.contains(digit) {
            throw AppError(L("打开面板和数字选取使用了同一组按键。请更换其中一项。"))
        }
        let reservedEditing = open.modifiers == cmdKey && ["A", "C", "V", "W", "X", "Z"].contains(key)
        let reservedPanel = PanelShortcut.allCases.contains { shortcut in
            // 设置入口沿用应用菜单的按键；已发布的打开组合仍可读回。
            shortcut != .settings && shortcut != .close &&
                open.modifiers == OpenShortcut.modifierMask(shortcut.keyModifiers) &&
                shortcut.matches(code: open.code, key: key, modifiers: shortcut.keyModifiers)
        }
        let confirmation = OpenShortcut.modifierMask(confirm.keyModifiers)
        let confirmCode = confirm == .tab ? open.code == kVK_Tab : [kVK_Return, kVK_ANSI_KeypadEnter].contains(open.code)
        let reservedConfirmation = confirmCode && (open.modifiers == confirmation || open.modifiers == (confirmation | shiftKey))
        if reservedEditing || reservedPanel || reservedConfirmation {
            throw AppError(L("%@ 已用于编辑或窗口操作，请选择其他组合。", open.displayTitle(layout: layout)))
        }
    }
}
