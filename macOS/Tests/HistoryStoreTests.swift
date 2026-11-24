import AppKit
import CryptoKit

@MainActor
enum HistoryStoreTests {
    static func membership(_ directory: URL) throws {
        let url = directory.appendingPathComponent("history.db")
        let key = SymmetricKey(size: .bits256)
        let store = try HistoryStore(url: url, key: key)
        let db = try HistoryDatabase(url)
        let lines = Set(try TestProject.source("App").split(separator: "\n").map(String.init)).sorted()
        let count = store.historyLimit + 2
        try Tests.expect(lines.count >= count, "源码夹具有足够不同的行")
        var ids = [String]()
        for line in lines.prefix(count) {
            let entry = try store.save(.text(line))
            try store.addFavorite(entry.id)
            ids.append(entry.id)
        }
        try store.addFavorite(ids.last!)
        try Tests.rejects("收藏不存在的历史") { try store.addFavorite("missing") }
        let expectedHistory = Array(ids.suffix(store.historyLimit).reversed())
        try Tests.expect(try store.load().map(\.id) == expectedHistory && store.favorites.map(\.id) == ids, "淘汰最旧历史并保留全部收藏")
        try Tests.expect(try Tests.number(db, "SELECT COUNT(*) FROM records") == count, "每份内容仅占一行")

        // 重新赋予最旧的两行历史身份，模拟已有数据库超出上限。
        try db.exec("UPDATE records SET history_rank=favorite_rank, history_at=favorite_at")
        try Tests.expect(try store.load().map(\.id) == expectedHistory, "启动时按顺位裁剪")
        try Tests.expect(try Tests.number(db, "SELECT COUNT(*) FROM records WHERE history_rank IS NOT NULL") == store.historyLimit, "裁剪写回磁盘")
        try Tests.expect(store.favorites.map(\.id) == ids, "裁剪时保留收藏")
        let first = store.favorites[0]
        let date = first.date
        try store.recordUse(of: first)
        try Tests.expect(store.entries.first?.id == first.id && store.favorites[0].date == date, "从收藏回到历史且保留收藏日期")
        let duplicate = try store.save(.text(lines[0]))
        try Tests.expect(duplicate.id == first.id && store.entries.count == store.historyLimit, "重复复制合并")
        try store.moveFavorite(ids[0], relativeTo: ids[2], insertAfter: true)
        let moved = ids.removeFirst()
        ids.insert(moved, at: 2)
        let reopened = try HistoryStore(url: url, key: key)
        try Tests.expect(try reopened.load().map(\.id) == store.entries.map(\.id) && reopened.favorites.map(\.id) == ids, "重开保留历史与拖动后的收藏顺序")
        try reopened.delete(duplicate.id)
        try Tests.expect(reopened.entries.count == reopened.historyLimit - 1 && reopened.favorites.contains { $0.id == duplicate.id }, "删除历史保留收藏")
        _ = try reopened.save(.text(lines[0]))
        try reopened.removeFavorite(duplicate.id)
        try Tests.expect(reopened.entries.first?.id == duplicate.id && !reopened.favorites.contains { $0.id == duplicate.id }, "取消收藏保留历史")
        try reopened.clear()
        try Tests.expect(try reopened.load().isEmpty && reopened.favorites.count == count - 1, "清空历史保留收藏")
        try Tests.expect(try Tests.number(db, "SELECT COUNT(*) FROM records WHERE id=?", [.text(duplicate.id)]) == 0, "双重身份移除后删除整行")
    }

    static func favoriteCopies(_ directory: URL) throws {
        let url = directory.appendingPathComponent("history.db")
        let key = SymmetricKey(size: .bits256)
        let store = try HistoryStore(url: url, key: key)
        let picture = try Tests.icon()
        let sourceText = try TestProject.source("App")
        let rich = try Tests.richText()
        guard case let .text(_, html?, rtf?) = rich else { throw AppError("富文本缺少格式。") }
        let payloads: [Payload] = [.text(sourceText), .files([directory.path]), picture, rich]
        for payload in payloads {
            let entry = try store.save(payload)
            try store.addFavorite(entry.id)
        }
        try store.clear()
        let wrong = try HistoryStore(url: url, key: SymmetricKey(size: .bits256))
        try Tests.rejects("收藏密钥错误") { _ = try wrong.load() }
        let reopened = try HistoryStore(url: url, key: key)
        try Tests.expect(try reopened.load().isEmpty && reopened.favorites.count == payloads.count, "错误密钥保留各收藏行")
        let pb = Tests.board()
        defer { pb.releaseGlobally() }
        let writer = ClipboardAccess(pb), reader = ClipboardAccess(pb)
        for (entry, payload) in zip(reopened.favorites, payloads) {
            try writer.write(reopened.payload(for: entry.id))
            try Tests.expect(try reader.read() == payload && entry.content == payload.content, "独立剪贴板恢复各类收藏")
        }
        guard let entry = reopened.favorites.first(where: { $0.id == HistoryStore.fingerprint(picture) }),
              let thumb = entry.thumbnail, case let .image(png, _, _) = picture else { throw AppError("缺少行缩略图。") }
        try Tests.expect(max(thumb.width, thumb.height) == 400, "重开后读取缩略图")
        let disk = try Data(contentsOf: url)
        for raw in [Data(sourceText.prefix(200).utf8), Data(directory.path.utf8), Data(png.prefix(80)), Data(html.prefix(80)), Data(rtf.prefix(80))] {
            try Tests.expect(disk.range(of: raw) == nil, "数据库未包含原始文本、文件路径、图片或富文本字节")
        }
        let db = try HistoryDatabase(url)
        try Tests.expect(try Tests.number(db, "SELECT COUNT(*) FROM records WHERE thumb IS NOT NULL AND substr(thumb,1,8)<>?", [.blob(Data(png.prefix(8)) as NSData)]) == 1,
                   "缩略图列中不含明文 PNG 文件头")
        try reopened.recordUse(of: entry)
        try reopened.removeFavorite(entry.id)
        try reopened.delete(entry.id)
        try Tests.expect(try Tests.number(db, "SELECT COUNT(*) FROM records WHERE id=?", [.text(entry.id)]) == 0, "删除仅在历史中的图像也删除缩略图")
    }

    static func corruption(_ directory: URL) throws {
        let url = directory.appendingPathComponent("history.db")
        let key = SymmetricKey(size: .bits256)
        let store = try HistoryStore(url: url, key: key)
        let keep = try store.save(.text(TestProject.source("HistoryViews")))
        let rich = try Tests.richText()
        let broken = try store.save(rich)
        try store.addFavorite(keep.id)
        try store.addFavorite(broken.id)
        let db = try HistoryDatabase(url)
        try db.write("UPDATE records SET text=substr(text,1,length(text)-1) WHERE id=?", [.text(broken.id)])
        try db.write("CREATE TEMP TABLE expected AS SELECT * FROM records WHERE id=?", [.text(broken.id)])
        // 归档后若原表删除失败，SQLite 应把整个操作回滚。
        try db.exec("CREATE TRIGGER deny_delete BEFORE DELETE ON records BEGIN SELECT RAISE(ABORT,'归档写入测试'); END")
        try Tests.rejects("归档中途失败") { _ = try store.load() }
        try Tests.expect(try Tests.number(db, "SELECT COUNT(*) FROM records") == 2, "归档失败保留原表")
        try db.exec("DROP TRIGGER deny_delete")
        try Tests.expect(try store.load().map(\.id) == [keep.id] && store.favorites.map(\.id) == [keep.id] && store.loadWarning != nil, "整行归档并提示")
        try Tests.expect(try Tests.number(db, "SELECT COUNT(*) FROM damaged_records") == 1 &&
                       Tests.number(db, "SELECT COUNT(*) FROM (SELECT * FROM expected EXCEPT SELECT * FROM damaged_records)") == 0,
                   "所有字段原值保留且只归档一次")
        let replacement = try store.save(rich)
        try store.addFavorite(replacement.id)
        let reopened = try HistoryStore(url: url, key: key)
        try Tests.expect(try reopened.load().map(\.id) == [broken.id, keep.id] && reopened.favorites.map(\.id) == [keep.id, broken.id] &&
                       reopened.loadWarning == nil, "重新收录曾损坏的同一内容")
        try db.exec("UPDATE records SET text=substr(text,1,length(text)-1)")
        try Tests.rejects("所有记录均损坏") { _ = try reopened.load() }
        try Tests.expect(try Tests.number(db, "SELECT COUNT(*) FROM records") == 2 && Tests.number(db, "SELECT COUNT(*) FROM damaged_records") == 1,
                   "全部失败保留原有记录和档案")
    }

    static func fieldAuthentication(_ directory: URL) throws {
        let url = directory.appendingPathComponent("history.db")
        let key = SymmetricKey(size: .bits256)
        let store = try HistoryStore(url: url, key: key)
        let rich = try Tests.richText()
        guard case let .text(text, html?, rtf?) = rich else { throw AppError("富文本缺少格式。") }
        let first = try store.save(rich)
        let second = try store.save(.text(try TestProject.source("App"), html: html, rtf: rtf))
        let db = try HistoryDatabase(url)
        // 保留加密列供逐字节比对，观察去重是否只改日期与顺位。
        try db.exec("CREATE TEMP TABLE original AS SELECT id,text,html,rtf FROM records")
        _ = try store.save(rich)
        try Tests.expect(try Tests.number(db, "SELECT COUNT(*) FROM (SELECT id,text,html,rtf FROM records EXCEPT SELECT * FROM original)") == 0,
                   "重复收录不重新加密")
        try db.write("UPDATE records SET html=(SELECT html FROM records WHERE id=?) WHERE id=?", [.text(second.id), .text(first.id)])
        try db.write("UPDATE records SET rtf=html WHERE id=?", [.text(second.id)])
        let reopened = try HistoryStore(url: url, key: key)
        try Tests.expect(try reopened.load().count == 2 && reopened.loadWarning == nil, "加载时不解密 HTML、RTF")
        try Tests.expect(reopened.entries.first?.content == .text(text), "轻量文字仍可用于纯文本复制")
        try Tests.rejects("移入其他行的 HTML 密文") { _ = try reopened.payload(for: first.id) }
        try Tests.rejects("将 HTML 密文置于 RTF 列") { _ = try reopened.payload(for: second.id) }
        let picture = try store.save(Tests.icon())
        try db.write("UPDATE records SET png=substr(png,1,length(png)-1) WHERE id=?", [.text(picture.id)])
        try Tests.expect(try reopened.load().first?.thumbnail != nil && reopened.loadWarning == nil, "原图损坏不影响启动和行缩略图")
        try Tests.rejects("按需读取损坏原图") { _ = try reopened.payload(for: picture.id) }
    }

    static func legacyBackup(_ directory: URL) throws {
        let url = directory.appendingPathComponent("history.db")
        let backup = directory.appendingPathComponent("history.v1.db")
        let key = SymmetricKey(size: .bits256)
        let json = try JSONSerialization.data(withJSONObject: ["kind": "text", "text": try TestProject.source("App"), "width": 0, "height": 0],
                                               options: [.sortedKeys])
        guard let sealed = try AES.GCM.seal(json, using: key).combined else { throw AppError("无法生成旧格式记录。") }
        let id = SHA256.hash(data: json).map { String(format: "%02x", $0) }.joined()
        // 按冻结的旧版字段和加密方式写入真实 SQLite 文件。
        let old = try HistoryDatabase(url)
        for table in ["history", "favorites"] {
            try old.exec("CREATE TABLE \(table)(id TEXT PRIMARY KEY, copied_at REAL NOT NULL, position INTEGER NOT NULL, payload BLOB NOT NULL)")
            try old.write("INSERT INTO \(table) VALUES (?,?,1,?)", [.text(id), .real(Date().timeIntervalSince1970), .blob(sealed as NSData)])
        }
        try old.exec("PRAGMA user_version=1")
        try old.close()
        let original = try Data(contentsOf: url)
        let store = try HistoryStore(url: url, key: key)
        try Tests.expect(try store.load().isEmpty && store.favorites.isEmpty, "旧库留存后从空库开始")
        try Tests.expect(try Data(contentsOf: backup) == original, "可完整找回旧库")
        let db = try HistoryDatabase(url)
        try Tests.expect(try Tests.number(db, "PRAGMA user_version") == 4, "新库记录格式版本")
        let entry = try store.save(.text(TestProject.source("App")))
        let reopened = try HistoryStore(url: url, key: key)
        try Tests.expect(try reopened.load().map(\.id) == [entry.id] && Data(contentsOf: backup) == original, "再次启动只读取新库")
    }
}
