import Carbon
import Foundation

package enum PanelShortcut: CaseIterable {
    case search, preview, favorite, lists, delete, clear, close, settings, quit

    package var equivalent: String {
        switch self {
        case .search: return "f"
        case .preview: return "i"
        case .favorite: return "d"
        case .lists: return "l"
        case .delete, .clear: return "\u{8}"
        case .close: return "\u{1b}"
        case .settings: return ","
        case .quit: return "q"
        }
    }
    package var keyModifiers: KeyModifiers {
        switch self {
        case .clear: return [.command, .option]
        case .close: return []
        default: return .command
        }
    }
    package var hint: String {
        let symbol: String
        switch self {
        case .delete, .clear: symbol = "⌫"
        case .close: return "Esc"
        default: symbol = equivalent.uppercased()
        }
        let prefix = OpenShortcut.modifierTitle(OpenShortcut.modifierMask(keyModifiers))
        return prefix + (self == .lists || self == .quit ? " " : "") + symbol
    }
    package var menuTitle: String {
        switch self {
        case .search: return L("搜索")
        case .preview: return L("查看内容")
        case .favorite: return L("收藏")
        case .lists: return L("查看收藏")
        case .delete: return L("删除此条")
        case .clear: return L("清空历史")
        case .close: return L("关闭")
        case .settings: return L("打开设置")
        case .quit: return L("退出")
        }
    }
    package func matches(code: Int, key: String?, modifiers: KeyModifiers) -> Bool {
        switch self {
        case .close: return code == kVK_Escape
        case .delete, .clear: return code == kVK_Delete && modifiers == keyModifiers
        default: return key?.lowercased() == equivalent && modifiers == keyModifiers
        }
    }
    package static var help: String {
        [[Self.search, .preview, .favorite, .lists], [.delete, .clear, .close]]
            .map { $0.map { ($0 == .preview ? "\(L("空格"))/\($0.hint)" : $0.hint) + " \($0.helpTitle)" }.joined(separator: " · ") }
            .joined(separator: "\n")
    }
    private var helpTitle: String {
        switch self {
        case .favorite: return L("收藏/取消")
        case .lists: return L("切换收藏")
        case .delete: return L("删除所选")
        default: return menuTitle
        }
    }
}
