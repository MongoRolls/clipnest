import Foundation

/// 面板按键使用的修饰键集合，与 AppKit 事件类型解耦。只包含参与按键判断的五个修饰键，
/// 大写锁定等其他标志在界面层转换时丢弃。
package struct KeyModifiers: OptionSet, Hashable, Sendable {
    package let rawValue: Int
    package init(rawValue: Int) { self.rawValue = rawValue }

    package static let command = KeyModifiers(rawValue: 1 << 0)
    package static let option = KeyModifiers(rawValue: 1 << 1)
    package static let control = KeyModifiers(rawValue: 1 << 2)
    package static let shift = KeyModifiers(rawValue: 1 << 3)
    package static let function = KeyModifiers(rawValue: 1 << 4)
}

/// 数字选取的修饰键。原始值属于已发布的 `keyboardSettings` 格式，不得改名。
package enum HistoryShortcut: String, CaseIterable, Codable {
    case fn, command, option, control

    package var keyModifier: KeyModifiers {
        switch self {
        case .fn: return .function
        case .command: return .command
        case .option: return .option
        case .control: return .control
        }
    }
    package var title: String {
        switch self {
        case .fn: return "fn"
        case .command: return "⌘"
        case .option: return "⌥"
        case .control: return "⌃"
        }
    }
    package static let numbers = 1...9

    package func index(characters: String?, modifiers: KeyModifiers) -> Int? {
        guard modifiers == keyModifier,
              let characters, characters.count == 1,
              let number = Int(characters), Self.numbers.contains(number) else { return nil }
        return number - 1
    }

    package func label(for index: Int) -> String {
        Self.numbers.contains(index + 1) ? "\(title) \(index + 1)" : ""
    }
}
