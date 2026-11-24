import AppKit

/// 把键盘事件交给 `PanelKeyRouting` 判断，并在搜索未完成时暂存依赖结果的动作。
@MainActor
final class PanelKeyRouter {
    typealias Action = PanelKeyAction
    private var pending: [Action] = []
    private var requests = RequestGuard()

    func cancelPending() {
        pending.removeAll()
        requests.invalidate()
    }

    func route(_ event: NSEvent, keyboard: KeyboardSettings, state: PanelKeyState, perform: (Action) -> Void) -> Bool {
        guard let action = PanelKeyRouting.action(for: KeyStroke(event), keyboard: keyboard, state: state) else { return false }
        if state.searching && action.needsResults { pending.append(action) }
        else { perform(action) }
        return true
    }

    func deliverPending(while canPerform: () -> Bool, perform: (Action) -> Void) {
        let ticket = requests.ticket
        let actions = pending
        pending.removeAll()
        for action in actions {
            guard requests.isCurrent(ticket), canPerform() else { break }
            perform(action)
        }
    }
}

// MARK: - AppKit 适配：核心按键模型与 NSEvent、菜单项和当前键盘布局之间的转换。

extension KeyModifiers {
    private static let flagPairs: [(KeyModifiers, NSEvent.ModifierFlags)] = [
        (.command, .command), (.option, .option), (.control, .control), (.shift, .shift), (.function, .function)
    ]

    init(_ flags: NSEvent.ModifierFlags) {
        self = Self.flagPairs.reduce(into: []) { if flags.contains($1.1) { $0.insert($1.0) } }
    }

    var eventFlags: NSEvent.ModifierFlags {
        Self.flagPairs.reduce(into: []) { if contains($1.0) { $0.insert($1.1) } }
    }
}

extension KeyStroke {
    init(_ event: NSEvent) {
        self.init(code: Int(event.keyCode), characters: event.charactersIgnoringModifiers, modifiers: KeyModifiers(event.modifierFlags))
    }
}

extension ConfirmationKey {
    var flags: NSEvent.ModifierFlags { keyModifiers.eventFlags }
}

extension OpenShortcut {
    static func modifierMask(_ flags: NSEvent.ModifierFlags) -> Int { modifierMask(KeyModifiers(flags)) }
    static func keyTitle(_ code: Int) -> String { keyTitle(code, layout: KeyboardLayout.characters(for:)) }
    var title: String { displayTitle(layout: KeyboardLayout.characters(for:)) }
}

extension KeyboardSettings {
    func validate() throws { try validate(layout: KeyboardLayout.characters(for:)) }
}

extension PanelShortcut {
    var modifiers: NSEvent.ModifierFlags { keyModifiers.eventFlags }

    @MainActor func apply(to item: NSMenuItem) {
        item.keyEquivalent = equivalent
        item.keyEquivalentModifierMask = modifiers
    }
}
