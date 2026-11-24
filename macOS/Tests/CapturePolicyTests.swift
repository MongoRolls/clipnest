import AppKit
import CryptoKit

@MainActor
enum CapturePolicyTests {
    static func capture(_ directory: URL) throws {
        let board = NSPasteboard(name: .init("com.clipnest.capture-tests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let store = try HistoryStore(url: directory.appendingPathComponent("history.db"), key: SymmetricKey(size: .bits256))
        let reader = ClipboardAccess(board), writer = ClipboardAccess(board)
        let source = try TestProject.source("App")
        let allowed = try TestProject.source("HistorySearch")

        reader.updateCapturePolicy(paused: true, ignoredBundleIDs: [])
        try writer.write(.text(source))
        try Tests.expect(try !reader.capture(in: store) && reader.handledSequence == board.changeCount, "暂停时跳过并记住剪贴板版本")
        try writer.write(.text(allowed))
        reader.updateCapturePolicy(paused: false, ignoredBundleIDs: [])
        try Tests.expect(try !reader.capture(in: store) && store.entries.isEmpty, "恢复时不补录最后一次轮询之后的内容")
        try writer.write(.text(allowed))
        try Tests.expect(try reader.capture(in: store) && store.entries.count == 1, "恢复后相同文本的新复制可以收录")

        guard let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder"),
              let ignored = Bundle(url: finder)?.bundleIdentifier else { throw AppError("未找到访达的应用标识。") }
        reader.updateCapturePolicy(paused: false, ignoredBundleIDs: [ignored])
        try writer.write(.text(source))
        reader.observeSource(ignored, sequence: board.changeCount)
        try reader.write(.text(allowed), preservingChangesIn: store)
        try Tests.expect(try writer.read() == .text(allowed) && store.entries.count == 1, "回填前跳过已观察到的被忽略应用版本")
        reader.updateCapturePolicy(paused: true, ignoredBundleIDs: [])
        try writer.write(.text(source))
        try reader.write(.text(allowed), preservingChangesIn: store)
        try Tests.expect(try store.load().map(\.content) == [.text(allowed)], "暂停时回填也不收录外部内容")
    }

    static func retention(_ directory: URL) throws {
        let url = directory.appendingPathComponent("history.db"), key = SymmetricKey(size: .bits256)
        let store = try HistoryStore(url: url, key: key, historyLimit: 100)
        let source = try TestProject.source("App")
        let lines = Set(source.split(separator: "\n").map(String.init)).sorted().prefix(101)
        var ids: [String] = []
        for line in lines {
            let entry = try store.save(.text(line))
            ids.append(entry.id)
            if ids.count == 1 { try store.addFavorite(entry.id) }
        }
        try Tests.expect(ids.count == 101 && store.entries.map(\.id) == Array(ids.suffix(100).reversed()), "写入时使用配置的 100 条上限")
        try store.setHistoryLimit(50)
        let remaining = Array(ids.suffix(50).reversed())
        try Tests.expect(store.entries.map(\.id) == remaining && store.favorites.map(\.id) == Array(ids.prefix(1)), "立即裁剪历史，保留收藏")
        let reopened = try HistoryStore(url: url, key: key, historyLimit: 500)
        try Tests.expect(try reopened.load().map(\.id) == remaining && reopened.favorites.map(\.id) == Array(ids.prefix(1)), "重开或调大上限后，已裁剪的历史保持删除")
    }
}
