import AppKit
import CryptoKit

@MainActor
enum ImageOCRTests {
    static func picture(_ text: String) throws -> Payload {
        let width = 1440, height = 220
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw AppError("无法创建识别用图片。")
        }
        context.setFillColor(CGColor.white)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        (text as NSString).draw(at: NSPoint(x: 38, y: 76), withAttributes: [
            .font: NSFont.systemFont(ofSize: 54), .foregroundColor: NSColor.black
        ])
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { throw AppError("无法读取识别用图片。") }
        return .image(png: try ClipImage.png(image), width: width, height: height)
    }

    static func recognition(_ directory: URL) throws {
        guard case let .image(png, width, height) = try picture("ClipNest OCR 2026 剪贴板测试"),
              case let .image(blank, _, _) = try picture("") else { throw AppError("缺少识别用图片。") }
        let text = try ImageOCR.recognize(pngData: png, expectedSize: (width, height), maxPixelSize: 2400)
        try Tests.expect(text.localizedCaseInsensitiveContains("ClipNest") && text.contains("2026") &&
                         text.contains("剪贴板"), "本地识别中英文混排")
        try Tests.expect(try ImageOCR.recognize(pngData: blank, expectedSize: (width, height),
                                               maxPixelSize: 4096).isEmpty, "无字图片返回空文本")
        let cancellation = CancellationToken()
        cancellation.cancel()
        do {
            _ = try ImageOCR.recognize(pngData: png, expectedSize: (width, height), maxPixelSize: 2400,
                                       cancellation: cancellation)
            throw AppError("已取消的图片文字识别仍然执行。")
        } catch is CancellationError {}
    }

    static func service(_ directory: URL) throws {
        let board = NSPasteboard(name: .init("com.clipnest.ocr-tests.\(UUID().uuidString)"))
        var errors: [Error] = []
        let service = HistoryService(clipboard: ClipboardAccess(board)) { _, error in errors.append(error) }
        defer { service.stop { board.releaseGlobally() } }
        let database = directory.appendingPathComponent("history.db")
        let key = SymmetricKey(size: .bits256)
        let history = try picture("ClipNest History")
        let favorite = try picture("ClipNest Favorites")
        let historyID = HistoryStore.fingerprint(history), favoriteID = HistoryStore.fingerprint(favorite)
        service.setAutoOCREnabled(false)
        service.start {
            let store = try HistoryStore(url: database, key: key)
            try store.save(history)
            try store.save(favorite)
            try store.addFavorite(favoriteID)
            try store.delete(favoriteID)
            return store
        }
        try PanelTests.wait(for: "加载待识别图片") { service.ready || !errors.isEmpty }
        if let error = errors.first { throw error }
        try Tests.expect(service.entries.first?.id == historyID && service.favorites.first?.id == favoriteID,
                         "识别前有一张普通图片及一张仅在收藏中的图片")
        // 自动识别已选中历史图片。同一轮事件里附加手动请求，再关闭后台索引。
        service.setAutoOCREnabled(true)
        var results: [Result<String, Error>] = []
        service.recognizeImageText(for: historyID) { results.append($0) }
        service.recognizeImageText(for: historyID) { results.append($0) }
        service.setAutoOCREnabled(false)
        try Tests.expect(service.isIdle, "识别不锁住面板操作")
        try PanelTests.wait(for: "完成同一图片的两个手动请求", timeout: 40) { results.count == 2 || !errors.isEmpty }
        if let error = errors.first { throw error }
        let recognized = try results.map { try $0.get() }
        try Tests.expect(recognized[0].contains("History") && recognized[0] == recognized[1] &&
                         service.entries.first?.ocrText == recognized[0], "手动请求收到已发布的识别结果")
        try Tests.expect(service.favorites.first?.ocrText == nil, "关闭后台识别后不继续处理收藏")
        var cache: Result<String, Error>?
        service.recognizeImageText(for: historyID) { cache = $0 }
        try Tests.expect(try cache?.get() == recognized[0], "手动请求可立即读取缓存")

        service.setAutoOCREnabled(true)
        try PanelTests.wait(for: "补齐收藏图片索引", timeout: 40) { service.favorites.first?.ocrText != nil || !errors.isEmpty }
        if let error = errors.first { throw error }
        try Tests.expect(service.favorites.first?.ocrText?.contains("Favorites") == true, "自动识别仅在收藏中的图片")

        service.setAutoOCREnabled(false)
        // 先识别已占满单条容量的大图，再观察调度是否继续处理下一张。
        let full = try StorageMetadataTests.fullSizePicture(picture("ClipNest Capacity"))
        let next = try picture("Next image")
        let fullID = HistoryStore.fingerprint(full), nextID = HistoryStore.fingerprint(next)
        service.perform("保存容量边界图片", action: { store, _ in
            try store.save(next)
            try store.save(full)
        })
        try PanelTests.wait(for: "保存容量边界图片", timeout: 40) { service.entries.first?.id == fullID || !errors.isEmpty }
        if let error = errors.first { throw error }
        service.setAutoOCREnabled(true)
        var extracted: Result<String, Error>?
        service.recognizeImageText(for: fullID) { extracted = $0 }
        try PanelTests.wait(for: "完成大图及下一张图片的识别", timeout: 40) {
            extracted != nil && service.entries.contains { $0.id == nextID && $0.ocrText != nil }
        }
        try Tests.expect(errors.count == 1 && (errors.first as? AppError)?.code == .ocrIndexCapacity,
                         "单独报告索引容量错误，跳过这张图后继续识别")
        errors.removeAll()
        guard let extractedText = try extracted?.get(), extractedText.contains("Capacity") else {
            throw AppError("手动提取未拿到容量边界图片的真实文字。")
        }
        try Tests.expect(service.entries.first(where: { $0.id == fullID })?.ocrText == nil,
                         "容量不足时保留待识别状态")
        service.perform("复制容量边界图片文字", action: { store, clipboard in
            try clipboard.write(.text(extractedText), preservingChangesIn: store)
            // NSPasteboard 的类型缓存会在读取时修改，验证回读与轮询共用 worker。
            guard clipboard.pasteboard.string(forType: .string) == extractedText else {
                throw AppError("容量不足时复制出的文字与识别结果不一致。")
            }
        })
        try PanelTests.wait(for: "回填大图识别结果") { service.isIdle }
        if let error = errors.first { throw error }
        service.setAutoOCREnabled(false)
        let last = try picture("ClipNest Exit")
        let lastID = HistoryStore.fingerprint(last)
        service.perform("保存退出前的测试图片", action: { store, _ in try store.save(last) })
        try PanelTests.wait(for: "保存退出前的图片") { service.entries.first?.id == lastID || !errors.isEmpty }
        if let error = errors.first { throw error }
        var cancelled: Result<String, Error>?
        service.recognizeImageText(for: lastID) { cancelled = $0 }
        var stopReplies = 0
        service.stop { stopReplies += 1 }
        try PanelTests.wait(for: "退出时取消识别") { stopReplies > 0 && cancelled != nil }
        guard case .failure(let error) = cancelled, error is CancellationError else {
            throw AppError("退出时应取消尚未完成的识别请求。")
        }
        let reopened = try HistoryStore(url: database, key: key)
        try reopened.load()
        try Tests.expect(stopReplies == 1 && errors.isEmpty, "正常退出只回复一次且没有超时诊断")
        try Tests.expect(reopened.entries.first?.ocrText == nil && reopened.favorites.first?.ocrText?.contains("Favorites") == true,
                         "重开数据库保留已完成的结果，取消的图片仍待识别")
    }

    static func serviceLifecycle(_ directory: URL) throws {
        let url = directory.appendingPathComponent("history.db")
        let key = SymmetricKey(size: .bits256)
        let original = try HistoryStore(url: url, key: key)
        let entry = try original.save(.text("退出前保留的历史"))
        let lock = try HistoryDatabase(url)
        try lock.exec("BEGIN EXCLUSIVE")
        let board = NSPasteboard(name: .init("com.clipnest.shutdown-tests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        var diagnostics: [String] = []
        let service = HistoryService(clipboard: ClipboardAccess(board), recoveryURL: url, shutdownTimeout: 0.2) { action, _ in
            diagnostics.append(action)
        }
        let firstOwner = NSObject(), secondOwner = NSObject()
        var first = 0, second = 0
        service.observeChanges(owner: firstOwner) { _ in first += 1 }
        service.observeChanges(owner: secondOwner) { _ in second += 1 }
        service.start { try HistoryStore(url: url, key: key) }
        try Tests.expect(first > 0 && second > 0, "多个观察者均收到加载状态")
        service.removeObserver(firstOwner)
        let before = first
        try Tests.expect(!service.perform("载入时写入", action: { store, _ in try store.delete(entry.id) }),
                         "载入时明确拒绝写入")
        var replies = 0
        service.stop { replies += 1 }
        try PanelTests.wait(for: "等待真实 SQLite 独占锁时有界退出") { replies == 1 }
        try Tests.expect(diagnostics.filter { $0 == L("等待历史数据库退出") }.count == 1, "超时只写入一次诊断")
        try lock.exec("COMMIT")
        // 排在实际加载、退出清理后面的读取确认 worker 已恢复，同时验证一次请求只回复一次。
        var readFinished = false
        service.previewImage(for: entry.id) { _ in readFinished = true }
        try PanelTests.wait(for: "解除 SQLite 锁后处理剩余工作") { readFinished }
        try Tests.expect(replies == 1 && diagnostics.count == 1 && first == before && second > first && service.entries.first?.id == entry.id,
                         "迟到的清理不重复回复，已移除的观察者不再收到快照，拒绝的删除未执行")
    }
}
