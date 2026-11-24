import AppKit

/// 管理面板外的系统副作用：选后返回原应用与直接粘贴、单次辅助功能提示及清空历史确认弹窗。
@MainActor
final class PanelActions {
    enum ReturnOutcome: Equatable {
        case none, activated, needsAccessibility, pasted
    }
    private let service: HistoryService
    var onFailure: ((Error) -> Void)?
    var isAccessibilityGranted: () -> Bool = { SystemAccess.accessibilityGranted }
    var onPromptAccessibility: () -> Void = { SystemAccess.promptAccessibility() }
    var onActivate: (NSRunningApplication) -> Void = { Paster.activate($0) }
    var onPaste: (NSRunningApplication, @escaping () -> Bool, @escaping () -> Bool, @escaping (Error) -> Void) -> Void = Paster.paste
    /// 隔离剪贴板测试默认跳过直接粘贴，避免向当前前台应用发送 ⌘V；直接粘贴专项测试显式开启。
    var allowTestDirectPaste = false
    private var promptedAccessibility = false
    init(service: HistoryService) { self.service = service }

    func promptAccessibilityOnce() {
        guard !promptedAccessibility else { return }
        promptedAccessibility = true
        onPromptAccessibility()
    }

    @discardableResult
    func returnToTarget(_ target: NSRunningApplication?, version: Int, directPaste: Bool,
                        isCurrent: @escaping () -> Bool,
                        onNeedsAccessibility: () -> Void = {},
                        report: @escaping (Error) -> Void) -> ReturnOutcome {
        guard let target, !target.isTerminated else { return .none }
        guard directPaste, allowTestDirectPaste || service.usesGeneralPasteboard else {
            onActivate(target)
            return .activated
        }
        guard isAccessibilityGranted() else {
            onActivate(target)
            onNeedsAccessibility()
            return .needsAccessibility
        }
        onPaste(target, isCurrent, { self.service.ownsClipboard(sequence: version) }, report)
        return .pasted
    }

    func confirmClearHistory(beforeClear: () -> Void = {}) {
        guard service.isIdle, !service.entries.isEmpty else { return }
        let alert = NSAlert()
        alert.messageText = L("清空全部历史？")
        alert.informativeText = L("收藏记录和当前系统剪贴板不会被清空。")
        alert.addButton(withTitle: L("取消"))
        alert.addButton(withTitle: L("清空历史"))
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        beforeClear()
        service.clearHistory(onFailure: onFailure)
    }
}
