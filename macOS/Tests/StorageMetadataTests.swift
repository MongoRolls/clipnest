import AppKit
import CryptoKit
import SQLite3
import ImageIO
import UniformTypeIdentifiers

@MainActor
enum StorageMetadataTests {
    // 让 ImageIO 写入合法 PNG 描述，使真实图片精确达到单条上限，像素仍可由 Vision 解码。
    static func fullSizePicture(_ picture: Payload) throws -> Payload {
        guard case let .image(data, width, height) = picture,
              let image = CGImageSourceCreateImageAtIndex(try ClipImage.source(data), 0, nil) else {
            throw AppError("缺少可解码的容量测试图片。")
        }
        func encode(descriptionLength: Int) throws -> Data {
            let output = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else {
                throw AppError("无法创建带描述的 PNG。")
            }
            let properties = [kCGImagePropertyPNGDictionary: [kCGImagePropertyPNGDescription: String(repeating: "A", count: descriptionLength)]]
            CGImageDestinationAddImage(destination, image, properties as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw AppError("无法编码带描述的 PNG。") }
            return output as Data
        }
        let overhead = try encode(descriptionLength: 1).count - 1
        guard overhead < Limits.bytes else { throw AppError("容量测试源图已超过上限。") }
        let png = try encode(descriptionLength: Limits.bytes - overhead)
        try Tests.expect(png.count == Limits.bytes && ClipImage.size(png) == (width, height), "生成精确 64 MiB 的有效 PNG")
        return .image(png: png, width: width, height: height)
    }

    // 冻结 v2 的列顺序、认证数据与归档结构，直接写入真实密文再交给当前版本打开。
    private static let schemaV2 = """
        CREATE TABLE records(
            id TEXT PRIMARY KEY, kind INTEGER NOT NULL, width INTEGER NOT NULL, height INTEGER NOT NULL,
            history_rank INTEGER, history_at REAL, favorite_rank INTEGER, favorite_at REAL,
            text BLOB, thumb BLOB, html BLOB, rtf BLOB, png BLOB);
        CREATE INDEX history_order ON records(history_rank) WHERE history_rank IS NOT NULL;
        CREATE INDEX favorite_order ON records(favorite_rank) WHERE favorite_rank IS NOT NULL;
        CREATE INDEX unlisted_records ON records(id) WHERE history_rank IS NULL AND favorite_rank IS NULL;
        CREATE TABLE damaged_records AS SELECT * FROM records WHERE 0;
        PRAGMA user_version=2;
        """

    // 新建的 v3 数据库将来源和旧标签放在负载前，与 v2 升级过来的物理顺序不同。
    private static let schemaV3 = """
        CREATE TABLE records(
            id TEXT PRIMARY KEY, kind INTEGER NOT NULL, width INTEGER NOT NULL, height INTEGER NOT NULL,
            history_rank INTEGER, history_at REAL, favorite_rank INTEGER, favorite_at REAL,
            source_app BLOB, tags BLOB, text BLOB, thumb BLOB, html BLOB, rtf BLOB, png BLOB);
        CREATE INDEX history_order ON records(history_rank) WHERE history_rank IS NOT NULL;
        CREATE INDEX favorite_order ON records(favorite_rank) WHERE favorite_rank IS NOT NULL;
        CREATE INDEX unlisted_records ON records(id) WHERE history_rank IS NULL AND favorite_rank IS NULL;
        CREATE TABLE damaged_records AS SELECT * FROM records WHERE 0;
        PRAGMA user_version=3;
        """

    // 冻结 v4 的列顺序、认证数据与归档结构，作为后续版本升级与兼容性验证的基准样本。
    private static let schemaV4 = """
        CREATE TABLE records(
            id TEXT PRIMARY KEY, kind INTEGER NOT NULL, width INTEGER NOT NULL, height INTEGER NOT NULL,
            history_rank INTEGER, history_at REAL, favorite_rank INTEGER, favorite_at REAL,
            source_app BLOB, tags BLOB, ocr_text BLOB, text BLOB, thumb BLOB, html BLOB, rtf BLOB, png BLOB);
        CREATE INDEX history_order ON records(history_rank) WHERE history_rank IS NOT NULL;
        CREATE INDEX favorite_order ON records(favorite_rank) WHERE favorite_rank IS NOT NULL;
        CREATE INDEX unlisted_records ON records(id) WHERE history_rank IS NULL AND favorite_rank IS NULL;
        CREATE TABLE damaged_records AS SELECT * FROM records WHERE 0;
        PRAGMA user_version=4;
        """

    private static func insertLegacy(_ payload: Payload, id: String, rank: Int64, db: HistoryDatabase, key: SymmetricKey) throws {
        var kind: Int64 = 0, width = 0, height = 0
        var text: Data?, html: Data?, rtf: Data?, png: Data?, thumb: Data?
        switch payload {
        case let .text(value, h, r): text = Data(value.utf8); html = h; rtf = r
        case let .files(paths): kind = 2; text = Data(paths.joined(separator: "\0").utf8)
        case let .image(data, w, h):
            kind = 1; width = w; height = h; png = data
            thumb = try ClipImage.png(ClipImage.thumbnail(data, maxPixelSize: 400, expectedSize: (w, h)))
        }
        func field(_ data: Data?, _ name: String) throws -> HistoryDatabase.Value {
            guard let data else { return .null }
            let aad = Data("\(id):\(name):\(kind):\(width):\(height)".utf8)
            guard let bytes = try AES.GCM.seal(data, using: key, authenticating: aad).combined else {
                throw AppError("无法生成 v2 测试密文。")
            }
            return .blob(bytes as NSData)
        }
        try db.write("""
            INSERT INTO records(id,kind,width,height,history_rank,history_at,favorite_rank,favorite_at,text,thumb,html,rtf,png)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)
            """, [
            .text(id), .integer(kind), .integer(Int64(width)), .integer(Int64(height)), .integer(rank), .real(Double(rank)),
            .integer(rank), .real(Double(rank + 10)), try field(text, "text"), try field(thumb, "thumb"),
            try field(html, "html"), try field(rtf, "rtf"), try field(png, "png")
        ])
    }

    static func migration(_ directory: URL) throws {
        let url = directory.appendingPathComponent("history.db"), key = SymmetricKey(size: .bits256)
        let db = try HistoryDatabase(url)
        try db.exec(schemaV2)
        let rich = try Tests.richText(), picture = try Tests.icon()
        let files = Payload.files(["/System/Library/CoreServices/Finder.app"])
        let richID = HistoryStore.fingerprint(rich), pictureID = HistoryStore.fingerprint(picture)
        // 这一指纹取自固定的 v2 文件列表编码，可以独立检出指纹算法变化。
        let filesID = "e4790df8a7a5bf1805e65ff90550113ae8ed4fb4507c1f86d6baf9ee42f4dd79"
        let ids = [richID, pictureID, filesID]
        for (offset, pair) in zip([rich, picture, files], ids).enumerated() {
            try insertLegacy(pair.0, id: pair.1, rank: Int64(offset + 1), db: db, key: key)
        }
        try db.write("INSERT INTO damaged_records SELECT * FROM records WHERE id=?", [.text(richID)])
        try db.exec("UPDATE damaged_records SET text=substr(text,1,length(text)-1)")
        let originals = "id,kind,width,height,text,thumb,html,rtf,png"
        try db.exec("CREATE TEMP TABLE original_records AS SELECT \(originals) FROM records")
        try db.exec("CREATE TEMP TABLE original_archive AS SELECT \(originals) FROM damaged_records")

        let store = try HistoryStore(url: url, key: key)
        try Tests.expect(try db.userVersion() == 4 && !FileManager.default.fileExists(atPath: directory.appendingPathComponent("history.v1.db").path),
                         "原位升级 v2 数据库")
        try Tests.expect(try store.load().map(\.id) == ids.reversed() && store.favorites.map(\.id) == ids, "保留历史与收藏的独立顺位")
        try Tests.expect(store.favorites.map { $0.date.timeIntervalSince1970 } == [11, 12, 13] &&
                         store.entries.map { $0.date.timeIntervalSince1970 } == [3, 2, 1], "保留各顺位的原始日期")
        try Tests.expect(store.entries.allSatisfy { $0.sourceAppBundleID == nil && $0.ocrText == nil }, "旧记录来源与文字索引为空")
        for (id, payload) in zip(ids, [rich, picture, files]) {
            try Tests.expect(try store.payload(for: id) == payload, "升级后完整解密 v2 内容并校验指纹")
        }
        try Tests.expect(try Tests.number(db, "SELECT count(*) FROM (SELECT * FROM original_archive EXCEPT SELECT \(originals) FROM damaged_records)") == 0,
                         "原归档密文保持完整")
        let source = "com.apple.finder"
        let staleEntry = try store.save(rich, sourceApp: source)
        // 写入旧版实际使用的标签密文，检查后续收录仍保留该值。
        let oldTags = try RecordCipher(key: key).seal(JSONEncoder().encode(["README"]),
                                                      RecordHeader(id: richID, content: rich.content), "tags")
        try db.write("UPDATE records SET tags=? WHERE id=?", [oldTags, .text(richID)])
        _ = try store.recordUse(of: staleEntry)
        _ = try store.save(rich)
        try Tests.expect(store.entries.first?.sourceAppBundleID == source &&
                         store.favorites.first?.date.timeIntervalSince1970 == 11, "重复使用、未知来源及旧快照保留元数据与收藏日期")
        let disk = try Data(contentsOf: url)
        try Tests.expect(disk.range(of: Data(source.utf8)) == nil, "磁盘中没有来源明文")
        try Tests.expect(try Tests.number(db, "SELECT count(*) FROM (SELECT * FROM original_records EXCEPT SELECT \(originals) FROM records)") == 0,
                         "迁移和重复收录保留负载密文")

        let reopened = try HistoryStore(url: url, key: key)
        _ = try reopened.save(rich, sourceApp: "com.apple.Terminal")
        _ = try reopened.load()
        try Tests.expect(reopened.favorites.first?.sourceAppBundleID == "com.apple.Terminal" &&
                         Tests.number(db, "SELECT tags=? FROM records WHERE id=?", [oldTags, .text(richID)]) == 1,
                         "重开后先写再读，更新来源并保留旧标签密文")
        try db.write("UPDATE records SET source_app=tags WHERE id=?", [.text(richID)])
        try Tests.expect(try reopened.load().count == 2 && reopened.loadWarning != nil &&
                         Tests.number(db, "SELECT count(*) FROM damaged_records") == 2, "元数据列互换后，坏行完整进入已升级的归档")

        let blockedURL = directory.appendingPathComponent("rollback.db"), blocked = try HistoryDatabase(blockedURL)
        try blocked.exec(schemaV2)
        try blocked.exec("ALTER TABLE damaged_records ADD COLUMN tags BLOB")
        try Tests.rejects("归档结构冲突时中止迁移") { _ = try HistoryStore(url: blockedURL, key: key) }
        try Tests.expect(try blocked.userVersion() == 2 && Tests.number(blocked, "SELECT count(*) FROM pragma_table_info('records') WHERE name IN ('source_app','tags')") == 0,
                         "迁移中断回滚版本与主表变更")
    }

    static func ocrMigration(_ directory: URL) throws {
        let url = directory.appendingPathComponent("history.db"), key = SymmetricKey(size: .bits256)
        let db = try HistoryDatabase(url), cipher = RecordCipher(key: key)
        try db.exec(schemaV3)
        let picture = try Tests.icon(), document = try Tests.richText()
        let id = HistoryStore.fingerprint(picture), documentID = HistoryStore.fingerprint(document)
        try insertLegacy(picture, id: id, rank: 1, db: db, key: key)
        try insertLegacy(document, id: documentID, rank: 2, db: db, key: key)
        let header = RecordHeader(id: id, content: picture.content), source = "com.apple.finder"
        let tags = try cipher.seal(JSONEncoder().encode(["ClipNest"]), header, "tags")
        try db.write("UPDATE records SET source_app=?, tags=? WHERE id=?",
                     [try cipher.seal(Data(source.utf8), header, "source_app"), tags, .text(id)])
        try db.write("INSERT INTO damaged_records SELECT * FROM records WHERE id=?", [.text(documentID)])
        try db.exec("CREATE TEMP TABLE original_records AS SELECT * FROM records")
        let columns = "id,kind,width,height,history_rank,history_at,favorite_rank,favorite_at,source_app,tags,text,thumb,html,rtf,png"

        let store = try HistoryStore(url: url, key: key)
        try Tests.expect(try db.userVersion() == 4 && store.load().map(\.id) == [documentID, id] &&
                         store.favorites.map(\.id) == [id, documentID], "第三版原位升级保留两个列表的独立顺序")
        try Tests.expect(try Tests.number(db, "SELECT count(*) FROM (SELECT * FROM original_records EXCEPT SELECT \(columns) FROM records)") == 0 &&
                         Tests.number(db, "SELECT count(*) FROM records WHERE ocr_text IS NULL") == 2 &&
                         Tests.number(db, "SELECT count(*) FROM damaged_records WHERE ocr_text IS NULL") == 1,
                         "原始密文、旧标签和日期逐列保留，新增列在原记录与归档中均为空")
        try Tests.expect(store.entries.last?.ocrText == nil && store.entries.last?.sourceAppBundleID == source &&
                         store.favorites.first?.ocrText == nil, "第三版图片等待建立索引")
        let text = "ClipNest 本地图片文字"
        let update = try store.saveOCRText(text, for: id)
        try Tests.expect(update.updated && update.affectsFavorites && store.entries.last?.ocrText == text &&
                         store.favorites.first?.ocrText == text && store.entries.last?.date.timeIntervalSince1970 == 1 &&
                         store.favorites.first?.date.timeIntervalSince1970 == 11 && store.entries.last?.sourceAppBundleID == source,
                         "历史与收藏同时获得索引，保留各自日期和来源")
        try Tests.expect(try Data(contentsOf: url).range(of: Data(text.utf8)) == nil &&
                         Tests.number(db, "SELECT length(ocr_text) FROM records WHERE id=?", [.text(id)]) == text.utf8.count + 28,
                         "索引逐列加密保存")
        let reopened = try HistoryStore(url: url, key: key)
        try Tests.expect(try reopened.save(picture).ocrText == text && reopened.load().first?.ocrText == text &&
                         reopened.payload(for: id) == picture, "重启后重复收录保留索引，原图指纹保持有效")
        _ = try reopened.saveOCRText("", for: id)
        try Tests.expect(try reopened.load().first?.ocrText == "" &&
                         Tests.number(db, "SELECT length(ocr_text) FROM records WHERE id=?", [.text(id)]) == 28,
                         "无字图片持久保存已完成状态")
        let longText = String(repeating: "识", count: Limits.ocrBytes / 3 + 1)
        _ = try reopened.saveOCRText(longText, for: id)
        try Tests.expect(reopened.entries.first?.ocrText == String(longText.dropLast()), "索引按 UTF-8 上限裁剪并保留完整汉字")
        try reopened.delete(id)
        let favoriteOnly = try reopened.saveOCRText(text, for: id)
        try Tests.expect(favoriteOnly.affectsFavorites && reopened.favorites.first?.ocrText == text &&
                         !reopened.entries.contains { $0.id == id }, "仅剩收藏时更新其索引")
        try db.write("UPDATE records SET ocr_text=source_app WHERE id=?", [.text(id)])
        try db.write("CREATE TEMP TABLE expected_archive AS SELECT * FROM records WHERE id=?", [.text(id)])
        try Tests.expect(try reopened.load().map(\.id) == [documentID] && reopened.favorites.map(\.id) == [documentID] &&
                         Tests.number(db, "SELECT count(*) FROM (SELECT * FROM expected_archive EXCEPT SELECT * FROM damaged_records)") == 0,
                         "跨列调换密文后完整归档图片")
        try Tests.expect(try !reopened.saveOCRText(text, for: id).updated &&
                         !reopened.saveOCRText(text, for: documentID).updated, "跳过已移除的图片及非图片记录")
        _ = try reopened.save(picture)
        try db.write("UPDATE records SET ocr_text=? WHERE id=?",
                     [try cipher.seal(Data([0xFF]), header, "ocr_text"), .text(id)])
        try Tests.expect(try reopened.load().map(\.id) == [documentID], "归档已认证但编码无效的图片文字")
        _ = try reopened.save(picture)
        let documentHeader = RecordHeader(id: documentID, content: document.content)
        try db.write("UPDATE records SET ocr_text=? WHERE id=?",
                     [try cipher.seal(Data(), documentHeader, "ocr_text"), .text(documentID)])
        try Tests.expect(try reopened.load().map(\.id) == [id], "归档含有意外索引的文本")

        let blockedURL = directory.appendingPathComponent("rollback.db"), blocked = try HistoryDatabase(blockedURL)
        try blocked.exec(schemaV3)
        try blocked.exec("ALTER TABLE damaged_records ADD COLUMN ocr_text BLOB")
        try Tests.rejects("第三版归档列冲突") { _ = try HistoryStore(url: blockedURL, key: key) }
        try Tests.expect(try blocked.userVersion() == 3 &&
                         Tests.number(blocked, "SELECT count(*) FROM pragma_table_info('records') WHERE name='ocr_text'") == 0,
                         "第三版迁移失败后回滚版本和主表变更")
    }

    static func capture(_ directory: URL) throws {
        let board = NSPasteboard(name: .init("com.clipnest.source-tests.\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let key = SymmetricKey(size: .bits256), url = directory.appendingPathComponent("history.db")
        let store = try HistoryStore(url: url, key: key), reader = ClipboardAccess(board), writer = ClipboardAccess(board)
        let document = try Tests.richText()
        guard let finder = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.finder").flatMap({ Bundle(url: $0)?.bundleIdentifier }),
              let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.Terminal").flatMap({ Bundle(url: $0)?.bundleIdentifier }) else {
            throw AppError("未找到访达或终端的应用标识。")
        }
        let first = try writer.write(document)
        reader.observeSource(finder, sequence: first)
        reader.updateFrontmostApplication(terminal)
        reader.observeSource(terminal, sequence: first)
        try Tests.expect(try reader.capture(in: store) && store.entries.first?.sourceAppBundleID == finder, "应用切换后按该版本首次观察到的来源收录")
        let id = HistoryStore.fingerprint(document)
        try store.addFavorite(id)
        let next = try writer.write(document)
        reader.observeSource(terminal, sequence: next)
        try Tests.expect(try reader.capture(in: store) && store.entries.count == 1 &&
                         store.entries.first?.sourceAppBundleID == terminal && store.favorites.first?.sourceAppBundleID == terminal,
                         "其他应用再次复制同一内容时更新历史和收藏的来源")
        _ = try reader.write(document)
        try Tests.expect(try !reader.capture(in: store) && store.entries.first?.sourceAppBundleID == terminal, "本实例写入的内容保持原来源")
    }

    private static func sealV4(_ data: Data?, id: String, column: String, kind: Int64, width: Int, height: Int,
                               key: SymmetricKey) throws -> HistoryDatabase.Value {
        guard let data else { return .null }
        let aad = Data("\(id):\(column):\(kind):\(width):\(height)".utf8)
        guard let bytes = try AES.GCM.seal(data, using: key, authenticating: aad).combined else {
            throw AppError("无法生成 v4 冻结测试密文。")
        }
        return .blob(bytes as NSData)
    }

    private static func solidPNG(width: Int, height: Int, rgb: (UInt8, UInt8, UInt8)) throws -> Payload {
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            bytes[offset] = rgb.0
            bytes[offset + 1] = rgb.1
            bytes[offset + 2] = rgb.2
            bytes[offset + 3] = 255
        }
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let provider = CGDataProvider(data: Data(bytes) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: colorSpace, bitmapInfo: bitmapInfo,
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else {
            throw AppError("无法构造 v4 样本图片。")
        }
        return .image(png: try ClipImage.png(image), width: width, height: height)
    }

    static func v4Snapshot(_ directory: URL) throws {
        let url = directory.appendingPathComponent("history.db"), key = SymmetricKey(size: .bits256)
        let db = try HistoryDatabase(url)
        try db.exec(schemaV4)

        let rich = try Tests.richText(), richID = HistoryStore.fingerprint(rich)
        let files = Payload.files(["/System/Library/CoreServices/Finder.app"])
        let filesID = "e4790df8a7a5bf1805e65ff90550113ae8ed4fb4507c1f86d6baf9ee42f4dd79"
        let imagePending = try Tests.icon(), imagePendingID = HistoryStore.fingerprint(imagePending)
        let imageEmpty = try solidPNG(width: 2, height: 2, rgb: (24, 96, 180)), imageEmptyID = HistoryStore.fingerprint(imageEmpty)
        let imageIndexed = try solidPNG(width: 4, height: 2, rgb: (200, 80, 40)), imageIndexedID = HistoryStore.fingerprint(imageIndexed)
        let ocrPhrase = "ClipNest v4 冻结样本"

        func insertV4(_ payload: Payload, id: String, historyRank: Int64, historyAt: Double,
                      favoriteRank: Int64?, favoriteAt: Double?, sourceApp: String?, tags: Data?, ocrText: Data?) throws {
            var kind: Int64 = 0, width = 0, height = 0
            var text: Data?, html: Data?, rtf: Data?, png: Data?, thumb: Data?
            switch payload {
            case let .text(value, h, r): text = Data(value.utf8); html = h; rtf = r
            case let .files(paths): kind = 2; text = Data(paths.joined(separator: "\0").utf8)
            case let .image(data, w, h):
                kind = 1; width = w; height = h; png = data
                thumb = try ClipImage.png(ClipImage.thumbnail(data, maxPixelSize: 400, expectedSize: (w, h)))
            }
            try db.write("""
                INSERT INTO records(id,kind,width,height,history_rank,history_at,favorite_rank,favorite_at,source_app,tags,ocr_text,text,thumb,html,rtf,png)
                VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                """, [
                .text(id), .integer(kind), .integer(Int64(width)), .integer(Int64(height)),
                .integer(historyRank), .real(historyAt),
                favoriteRank.map(HistoryDatabase.Value.integer) ?? .null,
                favoriteAt.map(HistoryDatabase.Value.real) ?? .null,
                try sealV4(sourceApp.map { Data($0.utf8) }, id: id, column: "source_app", kind: kind, width: width, height: height, key: key),
                try sealV4(tags, id: id, column: "tags", kind: kind, width: width, height: height, key: key),
                try sealV4(ocrText, id: id, column: "ocr_text", kind: kind, width: width, height: height, key: key),
                try sealV4(text, id: id, column: "text", kind: kind, width: width, height: height, key: key),
                try sealV4(thumb, id: id, column: "thumb", kind: kind, width: width, height: height, key: key),
                try sealV4(html, id: id, column: "html", kind: kind, width: width, height: height, key: key),
                try sealV4(rtf, id: id, column: "rtf", kind: kind, width: width, height: height, key: key),
                try sealV4(png, id: id, column: "png", kind: kind, width: width, height: height, key: key)
            ])
        }

        try insertV4(rich, id: richID, historyRank: 1, historyAt: 101, favoriteRank: 1, favoriteAt: 201,
                     sourceApp: "com.apple.finder", tags: try JSONEncoder().encode(["v3-legacy"]), ocrText: nil)
        try insertV4(files, id: filesID, historyRank: 2, historyAt: 102, favoriteRank: nil, favoriteAt: nil,
                     sourceApp: nil, tags: nil, ocrText: nil)
        try insertV4(imagePending, id: imagePendingID, historyRank: 3, historyAt: 103, favoriteRank: 2, favoriteAt: 202,
                     sourceApp: "com.apple.Preview", tags: nil, ocrText: nil)
        try insertV4(imageEmpty, id: imageEmptyID, historyRank: 4, historyAt: 104, favoriteRank: nil, favoriteAt: nil,
                     sourceApp: nil, tags: nil, ocrText: Data())
        try insertV4(imageIndexed, id: imageIndexedID, historyRank: 5, historyAt: 105, favoriteRank: 3, favoriteAt: 203,
                     sourceApp: nil, tags: nil, ocrText: Data(ocrPhrase.utf8))
        try db.write("INSERT INTO damaged_records SELECT * FROM records WHERE id=?", [.text(richID)])
        try db.exec("UPDATE damaged_records SET text=substr(text,1,length(text)-1)")
        try db.exec("CREATE TEMP TABLE original_records AS SELECT * FROM records")
        try db.exec("CREATE TEMP TABLE original_archive AS SELECT * FROM damaged_records")

        let store = try HistoryStore(url: url, key: key)
        try Tests.expect(try db.userVersion() == 4 &&
                         !FileManager.default.fileExists(atPath: directory.appendingPathComponent("history.v1.db").path),
                         "v4 样本保持版本 4 且不产生旧库备份")
        let entries = try store.load()
        try Tests.expect(entries.map(\.id) == [imageIndexedID, imageEmptyID, imagePendingID, filesID, richID] &&
                         store.loadWarning == nil, "完整读取 v4 历史顺位且无加载告警")
        try Tests.expect(store.favorites.map(\.id) == [richID, imagePendingID, imageIndexedID] &&
                         store.favorites.map { $0.date.timeIntervalSince1970 } == [201, 202, 203],
                         "保留 v4 收藏顺位与收藏日期")
        let byID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        try Tests.expect(byID[richID]?.sourceAppBundleID == "com.apple.finder" &&
                         byID[imagePendingID]?.sourceAppBundleID == "com.apple.Preview" &&
                         byID[filesID]?.sourceAppBundleID == nil && byID[imageEmptyID]?.sourceAppBundleID == nil &&
                         byID[imageIndexedID]?.sourceAppBundleID == nil, "正确读取来源应用标识")
        try Tests.expect(byID[richID]?.ocrText == nil && byID[filesID]?.ocrText == nil &&
                         byID[imagePendingID]?.ocrText == nil && byID[imageEmptyID]?.ocrText == "" &&
                         byID[imageIndexedID]?.ocrText == ocrPhrase, "正确区分未识别、无字和已识别三种 OCR 状态")
        for (id, payload) in [(richID, rich), (filesID, files), (imagePendingID, imagePending),
                              (imageEmptyID, imageEmpty), (imageIndexedID, imageIndexed)] {
            try Tests.expect(try store.payload(for: id) == payload, "按需读取并校验 v4 完整负载：\(id)")
        }
        try Tests.expect(try Tests.number(db, "SELECT count(*) FROM (SELECT * FROM original_records EXCEPT SELECT * FROM records)") == 0 &&
                         Tests.number(db, "SELECT count(*) FROM (SELECT * FROM original_archive EXCEPT SELECT * FROM damaged_records)") == 0,
                         "打开冻结 v4 数据库时不改写已有密文或归档记录")
    }
}
