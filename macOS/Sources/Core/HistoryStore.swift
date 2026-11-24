import Foundation
import CoreGraphics
import CryptoKit

package final class HistoryStore {
    package struct DeletedEntry: Equatable {
        package let id: String
        package let fromFavorites: Bool
        let rank: Int64
        let date: Date
        let index: Int
    }

    package private(set) var entries: [Entry] = []
    package private(set) var favorites: [Entry] = []
    package private(set) var loadWarning: AppError?
    package private(set) var historyLimit: Int
    private let db: HistoryDatabase
    private let cipher: RecordCipher
    private let mapper: RecordMapper
    private var retainedIDs: [String: Int] = [:]

    private static let nextHistory = "(SELECT COALESCE(MAX(history_rank),0)+1 FROM records WHERE history_rank IS NOT NULL)"

    package init(url: URL, key: SymmetricKey, historyLimit: Int = Limits.defaultHistory) throws {
        guard Limits.historyChoices.contains(historyLimit) else { throw AppError(L("请选择有效的历史保留条数。"), code: .validation) }
        self.historyLimit = historyLimit
        db = try HistoryDatabase.open(url)
        cipher = RecordCipher(key: key)
        mapper = RecordMapper(cipher: cipher)
        try db.configureIncrementalVacuum()
        try SchemaMigrator.apply(to: db)
    }

    package static func fingerprint(_ payload: Payload) -> String { RecordCipher.fingerprint(payload) }

    // MARK: - 加载与读取

    @discardableResult
    package func load() throws -> [Entry] {
        var history: [(Int64, Entry)] = [], saved: [(Int64, Entry)] = []
        var damaged: [Int64] = [], firstError: Error?
        try db.transaction {
            try db.rows("SELECT \(RecordMapper.lightColumns) FROM records ORDER BY rowid") { row in
                do {
                    let h = try mapper.historyOrder(row), f = try mapper.favoriteOrder(row)
                    // 回填中断时可能留下无顺位记录，下面统一清理。
                    guard let date = h?.date ?? f?.date else { return }
                    var entry = try mapper.lightEntry(row, date: date)
                    if let h { history.append((h.rank, entry)) }
                    if let f { entry.date = f.date; saved.append((f.rank, entry)) }
                } catch {
                    damaged.append(mapper.rowID(row))
                    if firstError == nil { firstError = error }
                }
            }
            if let error = firstError {
                guard !history.isEmpty || !saved.isEmpty else {
                    throw AppError(L("所有记录均未通过校验，请检查密钥或数据库。%@", error.localizedDescription), code: .damagedDatabase)
                }
                // 归档允许同一 id 多次出现，保存每次受损的原始字段和密文。
                try db.exec("CREATE TABLE IF NOT EXISTS damaged_records AS SELECT * FROM records WHERE 0")
                for row in damaged {
                    try db.write("INSERT INTO damaged_records SELECT * FROM records WHERE rowid=?", [.integer(row)])
                    try db.write("DELETE FROM records WHERE rowid=?", [.integer(row)])
                }
            }
            try trimHistory(to: historyLimit)
        }
        entries = history.sorted { $0.0 > $1.0 }.prefix(historyLimit).map(\.1)
        favorites = saved.sorted { $0.0 < $1.0 }.map(\.1)
        loadWarning = firstError.map { AppError(L("已保留 %ld 条异常记录的原始数据。%@", damaged.count, $0.localizedDescription)) }
        return entries
    }

    /// 切换界面语言时仅重建内存中的展示文本和模糊词，避免重读磁盘和重复解码缩略图。
    package func relocalize() {
        entries = entries.map { $0.relocalized() }
        favorites = favorites.map { $0.relocalized() }
    }

    package func cachedEntry(_ id: String) -> Entry? {
        entries.first(where: { $0.id == id }) ?? favorites.first(where: { $0.id == id })
    }

    package func payload(for id: String) throws -> Payload {
        var result: Payload?
        try db.rows("SELECT \(RecordMapper.payloadColumns) FROM records WHERE id=?", [.text(id)]) { row in
            result = try mapper.payload(row)
        }
        guard let result else { throw AppError(L("记录已不存在。")) }
        try result.validate()
        // 复制时也校验可空列被截掉的情形，启动不读取这些列。
        guard Self.fingerprint(result) == id else { throw AppError(L("记录的内容指纹校验失败。")) }
        return result
    }

    private func fetchLightEntry(id: String, date: Date) throws -> Entry? {
        var entry: Entry?
        try db.rows("SELECT \(RecordMapper.lightColumns) FROM records WHERE id=?", [.text(id)]) {
            entry = try mapper.lightEntry($0, date: date)
        }
        return entry
    }

    // MARK: - 收录、使用与图片文字索引

    @discardableResult
    package func save(_ payload: Payload, sourceApp: String? = nil) throws -> Entry {
        try payload.validate()
        if sourceApp?.isEmpty == true { throw AppError(L("来源应用标识无效。"), code: .validation) }
        let id = Self.fingerprint(payload)
        let date = Date()
        let entry = try db.transaction { () -> Entry in
            // 首次加载之前和淘汰保留期间，记录可能只在数据库里。
            if var existing = try cachedEntry(id) ?? fetchLightEntry(id: id, date: date) {
                if let sourceApp, sourceApp != existing.sourceAppBundleID {
                    let header = RecordHeader(id: id, content: existing.content)
                    try db.write("UPDATE records SET source_app=? WHERE id=?",
                                 [try cipher.seal(Data(sourceApp.utf8), header, "source_app"), .text(id)])
                    existing.sourceAppBundleID = sourceApp
                }
                try promote(id, date: date)
                existing.date = date
                return existing
            }
            let header = RecordHeader(id: id, content: payload.content)
            var text: Data?, html: Data?, rtf: Data?, png: Data?, thumb: Data?, image: CGImage?
            switch payload {
            case let .text(string, h, r): text = Data(string.utf8); html = h; rtf = r
            case let .files(paths): text = Data(paths.joined(separator: "\0").utf8)
            case let .image(data, width, height):
                let small = try ClipImage.thumbnail(data, maxPixelSize: Tuning.thumbnailMaxPixelSize, expectedSize: (width, height))
                image = small; thumb = try ClipImage.png(small); png = data
            }
            try db.write("""
                INSERT INTO records(id,kind,width,height,text,html,rtf,png,thumb,source_app,history_rank,history_at)
                VALUES(?,?,?,?,?,?,?,?,?,?,\(Self.nextHistory),?)
                """, [.text(id), .integer(header.kind), .integer(Int64(header.width)), .integer(Int64(header.height)),
                      try cipher.seal(text, header, "text"), try cipher.seal(html, header, "html"), try cipher.seal(rtf, header, "rtf"),
                      try cipher.seal(png, header, "png"), try cipher.seal(thumb, header, "thumb"),
                      try cipher.seal(sourceApp.map { Data($0.utf8) }, header, "source_app"), .real(date.timeIntervalSince1970)])
            try trimHistory(to: historyLimit)
            return Entry(id: id, date: date, content: payload.content, thumbnail: image,
                         sourceAppBundleID: sourceApp)
        }
        remember(entry)
        return entry
    }

    @discardableResult
    package func recordUse(of entry: Entry) throws -> Entry {
        // 复制期间的外部收录可能更新同一条记录的来源，优先使用后台最新快照。
        var updated = cachedEntry(entry.id) ?? entry
        updated.date = Date()
        try db.transaction { try promote(entry.id, date: updated.date) }
        remember(updated)
        return updated
    }

    @discardableResult
    package func saveOCRText(_ text: String, for id: String) throws -> (updated: Bool, affectsFavorites: Bool) {
        // 识别期间图片可能已淘汰或删除。仅更新仍有顺位的行，并保留原图、日期和顺位。
        let storedText: String? = try db.transaction {
            var image: (header: RecordHeader, pngLength: Int)?
            try db.rows("""
                SELECT \(RecordMapper.ocrTargetColumns) FROM records
                WHERE id=? AND kind=1 AND (history_rank IS NOT NULL OR favorite_rank IS NOT NULL)
                """, [.text(id)]) { image = try mapper.ocrTarget($0) }
            guard let image else { return nil }
            guard (1...Limits.bytes).contains(image.pngLength) else { throw AppError(L("记录的正文列无效。")) }
            let result = try Self.ocrPrefix(text, byteLimit: min(Limits.ocrBytes, Limits.bytes - image.pngLength))
            try db.write("UPDATE records SET ocr_text=? WHERE id=? AND kind=1",
                         [try cipher.seal(Data(result.utf8), image.header, "ocr_text"), .text(id)])
            return result
        }
        guard let storedText else { return (false, false) }
        let history = entries.firstIndex { $0.id == id }
        let favorite = favorites.firstIndex { $0.id == id }
        if let entry = history.map({ entries[$0] }) ?? favorite.map({ favorites[$0] }) {
            var updated = entry.withOCR(storedText)
            if let history { entries[history] = updated }
            if let favorite {
                updated.date = favorites[favorite].date
                favorites[favorite] = updated
            }
        }
        return (true, favorite != nil)
    }

    private static func ocrPrefix(_ text: String, byteLimit: Int) throws -> String {
        let bytes = text.utf8
        guard bytes.count > byteLimit else { return text }
        // 在 UTF-8 标量边界截断，避免损坏最后一个中文字符。
        var end = bytes.index(bytes.startIndex, offsetBy: byteLimit)
        while end.samePosition(in: text.unicodeScalars) == nil { bytes.formIndex(before: &end) }
        guard end != bytes.startIndex else {
            throw AppError(L("图片和识别文字合计超过 %ld MiB，无法保存文字索引。", Limits.recordSizeMiB), code: .ocrIndexCapacity)
        }
        return String(decoding: bytes[..<end], as: UTF8.self)
    }

    // MARK: - 收藏管理

    package func addFavorite(_ id: String) throws {
        if favorites.contains(where: { $0.id == id }) { return }
        guard let entry = entries.first(where: { $0.id == id }) else { throw AppError(L("历史记录不存在，无法收藏。")) }
        try db.write("""
            UPDATE records SET favorite_rank=(SELECT COALESCE(MAX(favorite_rank),0)+1 FROM records WHERE favorite_rank IS NOT NULL),favorite_at=history_at
            WHERE id=? AND history_rank IS NOT NULL AND favorite_rank IS NULL
            """, [.text(id)])
        guard db.changes == 1 else { throw AppError(L("历史记录不存在或已收藏。")) }
        favorites.append(entry)
    }

    package func moveFavorite(_ id: String, relativeTo neighborID: String, insertAfter: Bool) throws {
        guard let source = favorites.firstIndex(where: { $0.id == id }),
              let neighbor = favorites.firstIndex(where: { $0.id == neighborID }) else {
            throw AppError(L("拖动的收藏或目标收藏已不存在。"))
        }
        guard source != neighbor else { return }
        var destination = neighbor + (insertAfter ? 1 : 0)
        if source < destination { destination -= 1 }
        guard source != destination else { return }
        var reordered = favorites
        let entry = reordered.remove(at: source)
        reordered.insert(entry, at: destination)
        try db.transaction { try persistFavoriteRanks(reordered) }
        favorites = reordered
    }

    package func removeFavorite(_ id: String) throws {
        try db.transaction {
            try db.write("UPDATE records SET favorite_rank=NULL,favorite_at=NULL WHERE id=? AND favorite_rank IS NOT NULL", [.text(id)])
            guard db.changes == 1 else { throw AppError(L("收藏记录不存在，无法取消收藏。"), code: .database) }
            try clean()
        }
        db.reclaimFreePages(maxPages: 128)
        favorites.removeAll { $0.id == id }
    }

    private func persistFavoriteRanks(_ list: [Entry]) throws {
        for (index, entry) in list.enumerated() {
            try db.write("UPDATE records SET favorite_rank=?1 WHERE id=?2 AND (favorite_rank IS NULL OR favorite_rank<>?1)",
                         [.integer(Int64(index + 1)), .text(entry.id)])
        }
    }

    // MARK: - 删除、撤销与容量淘汰

    package func setHistoryLimit(_ limit: Int) throws {
        guard Limits.historyChoices.contains(limit) else { throw AppError(L("请选择有效的历史保留条数。"), code: .validation) }
        if limit < historyLimit {
            try db.transaction { try trimHistory(to: limit) }
            db.reclaimFreePages()
            if entries.count > limit { entries.removeLast(entries.count - limit) }
        }
        historyLimit = limit
    }

    package func delete(_ id: String) throws {
        try db.transaction {
            try db.write("UPDATE records SET history_rank=NULL,history_at=NULL WHERE id=?", [.text(id)])
            try clean()
        }
        db.reclaimFreePages(maxPages: 128)
        entries.removeAll { $0.id == id }
    }

    package func clear() throws {
        try db.transaction {
            try db.write("UPDATE records SET history_rank=NULL,history_at=NULL WHERE history_rank IS NOT NULL")
            try clean()
        }
        db.reclaimFreePages(maxPages: 4096)
        entries.removeAll()
    }

    package func deleteForUndo(_ id: String, fromFavorites: Bool) throws -> DeletedEntry? {
        let deleted: DeletedEntry? = try db.transaction {
            let columns = fromFavorites ? "favorite_rank,favorite_at" : "history_rank,history_at"
            var position: (rank: Int64, date: Date)?
            try db.rows("SELECT \(columns) FROM records WHERE id=?", [.text(id)]) { row in
                position = try mapper.order(row, at: 0)
            }
            guard let position else { return nil }
            let list = fromFavorites ? favorites : entries
            let index = list.firstIndex { $0.id == id } ?? 0
            let update = fromFavorites
                ? "UPDATE records SET favorite_rank=NULL,favorite_at=NULL WHERE id=? AND favorite_rank IS NOT NULL"
                : "UPDATE records SET history_rank=NULL,history_at=NULL WHERE id=? AND history_rank IS NOT NULL"
            try db.write(update, [.text(id)])
            return DeletedEntry(id: id, fromFavorites: fromFavorites, rank: position.rank, date: position.date, index: index)
        }
        guard let deleted else { return nil }
        // 事务提交后再登记保留计数，写入失败回滚时不会残留无法清理的引用。
        retainedIDs[id, default: 0] += 1
        if fromFavorites { favorites.removeAll { $0.id == id } }
        else { entries.removeAll { $0.id == id } }
        return deleted
    }

    @discardableResult
    package func restore(_ deleted: DeletedEntry) throws -> Bool {
        var restoredEntry: Entry?
        var insertIndex: Int?
        var alreadyListed = false
        var exists = false
        try db.transaction {
            var membership: (hasHistory: Bool, hasFavorite: Bool)?
            try db.rows("SELECT history_rank,favorite_rank FROM records WHERE id=?", [.text(deleted.id)]) { row in
                membership = mapper.membership(row)
            }
            guard let membership else { return }
            exists = true
            if deleted.fromFavorites {
                guard !membership.hasFavorite else { alreadyListed = true; return }
                guard let entry = try fetchLightEntry(id: deleted.id, date: deleted.date) else { return }
                var reordered = favorites
                let target = min(deleted.index, reordered.count)
                reordered.insert(entry, at: target)
                try db.write("UPDATE records SET favorite_at=? WHERE id=?", [.real(deleted.date.timeIntervalSince1970), .text(deleted.id)])
                try persistFavoriteRanks(reordered)
                restoredEntry = entry
                insertIndex = target
            } else {
                guard !membership.hasHistory else { alreadyListed = true; return }
                guard let entry = try fetchLightEntry(id: deleted.id, date: deleted.date) else { return }
                try db.write("UPDATE records SET history_rank=?,history_at=? WHERE id=?",
                             [.integer(deleted.rank), .real(deleted.date.timeIntervalSince1970), .text(deleted.id)])
                try trimHistory(to: historyLimit)
                if try db.exists("SELECT 1 FROM records WHERE id=? AND history_rank IS NOT NULL", [.text(deleted.id)]) {
                    let before = Int(try db.int64("SELECT COUNT(*) FROM records WHERE history_rank>?", [.integer(deleted.rank)]) ?? 0)
                    restoredEntry = entry
                    insertIndex = before
                }
            }
        }
        if let restoredEntry, let insertIndex {
            if deleted.fromFavorites {
                favorites.removeAll { $0.id == deleted.id }
                favorites.insert(restoredEntry, at: min(insertIndex, favorites.count))
            } else if insertIndex < historyLimit {
                entries.removeAll { $0.id == deleted.id }
                entries.insert(restoredEntry, at: min(insertIndex, entries.count))
                if entries.count > historyLimit { entries.removeLast(entries.count - historyLimit) }
            }
        }
        if retainedIDs[deleted.id] != nil { try releaseCaptureTail(deleted.id) }
        return exists && (alreadyListed || restoredEntry != nil)
    }

    package func discardDeleted(_ deleted: DeletedEntry) throws {
        guard retainedIDs[deleted.id] != nil else { return }
        try releaseCaptureTail(deleted.id)
        db.reclaimFreePages(maxPages: 128)
    }

    package func retainCaptureTail() -> String? {
        guard entries.count == historyLimit, let id = entries.last?.id,
              !favorites.contains(where: { $0.id == id }) else { return nil }
        retainedIDs[id, default: 0] += 1
        return id
    }

    package func releaseCaptureTail(_ id: String) throws {
        guard let count = retainedIDs[id] else { throw AppError(L("未找到需释放的历史记录。")) }
        if count > 1 { retainedIDs[id] = count - 1; return }
        retainedIDs.removeValue(forKey: id)
        if !entries.contains(where: { $0.id == id }) && !favorites.contains(where: { $0.id == id }) {
            try db.write("DELETE FROM records WHERE id=? AND history_rank IS NULL AND favorite_rank IS NULL", [.text(id)])
        }
    }

    package func withRetainedRecord<T>(_ id: String, _ body: () throws -> T) throws -> T {
        // 当前界面可能仍显示后台刚淘汰的一行。在覆盖剪贴板前确认密文仍可用于恢复历史。
        guard try db.exists("SELECT 1 FROM records WHERE id=?", [.text(id)]) else {
            throw AppError(L("该记录已被淘汰，请重新选择。"))
        }
        retainedIDs[id, default: 0] += 1
        let result = Result { try body() }
        do { try releaseCaptureTail(id) }
        catch {
            if case .failure(let original) = result {
                throw AppError(L("%@；清理历史失败：%@", original.localizedDescription, error.localizedDescription))
            }
            throw error
        }
        return try result.get()
    }

    private func remember(_ entry: Entry) {
        entries.removeAll { $0.id == entry.id }
        entries.insert(entry, at: 0)
        if entries.count > historyLimit { entries.removeLast(entries.count - historyLimit) }
        if let index = favorites.firstIndex(where: { $0.id == entry.id }),
           favorites[index].sourceAppBundleID != entry.sourceAppBundleID {
            favorites[index].sourceAppBundleID = entry.sourceAppBundleID
        }
    }

    private func trimHistory(to limit: Int) throws {
        try db.write("""
            UPDATE records SET history_rank=NULL,history_at=NULL WHERE rowid IN
                (SELECT rowid FROM records WHERE history_rank IS NOT NULL ORDER BY history_rank DESC,rowid LIMIT -1 OFFSET ?)
            """, [.integer(Int64(limit))])
        try clean()
    }

    private func clean() throws {
        let sql = "DELETE FROM records WHERE history_rank IS NULL AND favorite_rank IS NULL"
        guard !retainedIDs.isEmpty else { try db.write(sql); return }
        let slots = Array(repeating: "?", count: retainedIDs.count).joined(separator: ",")
        try db.write(sql + " AND id NOT IN (\(slots))", retainedIDs.keys.map(HistoryDatabase.Value.text))
    }

    private func promote(_ id: String, date: Date) throws {
        try db.write("UPDATE records SET history_rank=\(Self.nextHistory),history_at=? WHERE id=?", [.real(date.timeIntervalSince1970), .text(id)])
        guard db.changes == 1 else { throw AppError(L("历史记录不存在，无法更新复制时间。")) }
        try trimHistory(to: historyLimit)
    }
}
