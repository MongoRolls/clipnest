import Carbon
import Foundation

/// 一次按键的键码、忽略修饰键的字符和参与判断的修饰键，由界面层从键盘事件转换而来。
package struct KeyStroke: Equatable {
    package var code: Int
    package var characters: String?
    package var modifiers: KeyModifiers

    package init(code: Int, characters: String?, modifiers: KeyModifiers) {
        self.code = code
        self.characters = characters
        self.modifiers = modifiers
    }
}

/// 面板在按键当时的状态快照。
package struct PanelKeyState: Equatable {
    package var commands: Bool
    package var searching: Bool
    package var searchEmpty: Bool
    package var previewOpen: Bool
    package var hasEntries: Bool
    package var canUndoDelete: Bool

    package init(commands: Bool = false, searching: Bool = false, searchEmpty: Bool = true,
                 previewOpen: Bool = false, hasEntries: Bool = true, canUndoDelete: Bool = false) {
        self.commands = commands
        self.searching = searching
        self.searchEmpty = searchEmpty
        self.previewOpen = previewOpen
        self.hasEntries = hasEntries
        self.canUndoDelete = canUndoDelete
    }
}

package enum PanelKeyAction: Equatable {
    case shortcut(PanelShortcut)
    case togglePreview
    case undoDelete
    case numbered(Int)
    case step(Int)
    case confirm, confirmText, runCommand

    /// 依赖当前搜索结果的动作在搜索未完成时排队，结果到达后再执行。
    package var needsResults: Bool {
        switch self {
        case .numbered, .step, .confirm, .confirmText, .togglePreview, .shortcut(.favorite): return true
        default: return false
        }
    }
}

package enum PanelKeyRouting {
    /// 返回 nil 表示面板不处理该按键，交给搜索框或应用菜单。
    package static func action(for stroke: KeyStroke, keyboard: KeyboardSettings, state: PanelKeyState) -> PanelKeyAction? {
        let flags = stroke.modifiers
        let code = stroke.code
        if let index = keyboard.number.index(characters: stroke.characters, modifiers: flags) {
            return .numbered(index)
        }
        if code == kVK_Space && flags.subtracting(.function).isEmpty && !state.commands &&
            (state.previewOpen || (state.searchEmpty && state.hasEntries)) {
            return .togglePreview
        }
        if code == kVK_Delete && flags == [.command, .shift] && !state.commands { return .shortcut(.delete) }
        if state.canUndoDelete && flags == .command && stroke.characters?.lowercased() == "z" { return .undoDelete }
        if let shortcut = PanelShortcut.allCases.first(where: { $0.matches(code: code, key: stroke.characters, modifiers: flags) }) {
            // 设置和退出交给应用菜单，保留所有窗口的系统按键分派。
            if shortcut == .settings || shortcut == .quit { return nil }
            if shortcut == .delete && !state.searchEmpty { return nil }
            return shortcut == .preview ? .togglePreview : .shortcut(shortcut)
        }
        if code == kVK_DownArrow || code == kVK_UpArrow { return .step(code == kVK_DownArrow ? 1 : -1) }
        if state.commands && !state.searching {
            guard (code == kVK_Return || code == kVK_ANSI_KeypadEnter) && flags.subtracting(.function).isEmpty else { return nil }
            return .runCommand
        }
        if keyboard.confirm.matches(code: code, modifiers: flags) {
            return flags.contains(.shift) ? .confirmText : .confirm
        }
        return nil
    }
}
