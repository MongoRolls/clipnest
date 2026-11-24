import AppKit

enum PanelRowID: Equatable {
    case entry(String)
    case command(PanelCommand)
}

enum PanelContent {
    case entries([Entry], highlights: [String: [NSRange]])
    case commands([PanelCommand])
    case message(String)

    var entries: [Entry] {
        if case let .entries(entries, _) = self { return entries }
        return []
    }
    var commands: [PanelCommand]? {
        if case let .commands(commands) = self { return commands }
        return nil
    }
    var count: Int { commands?.count ?? entries.count }
    var emptyMessage: String? {
        switch self {
        case .message(let text): return text
        case .commands: return L("没有匹配的命令。")
        case .entries: return nil
        }
    }
    func highlights(for id: String) -> [NSRange] {
        if case let .entries(_, highlights) = self { return highlights[id] ?? [] }
        return []
    }
    func id(at row: Int) -> PanelRowID? {
        guard (0..<count).contains(row) else { return nil }
        if let commands { return .command(commands[row]) }
        return .entry(entries[row].id)
    }
    func rowHeight(at row: Int) -> CGFloat {
        if entries.indices.contains(row), case .image = entries[row].content { return HistoryLayout.imageRowHeight }
        return HistoryLayout.textRowHeight
    }
}
