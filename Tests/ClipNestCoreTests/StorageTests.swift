import CryptoKit
import Foundation
import SQLite3
import XCTest
@testable import ClipNestCore

final class StorageTests: XCTestCase {
    func testEncryptedRoundTripAndSearch() throws {
        let url = try CoreTestFiles.database(), key = SymmetricKey(size: .bits256)
        let original = try CoreTestFiles.source("HistoryStore")
        let payload = Payload.text(original)
        let store = try HistoryStore(url: url, key: key)
        let entry = try store.save(payload)
        try store.addFavorite(entry.id)
        let reopened = try HistoryStore(url: url, key: key)
        let entries = try reopened.load()
        XCTAssertEqual(entries.map(\.id), [entry.id])
        XCTAssertEqual(reopened.favorites.map(\.id), [entry.id])
        XCTAssertEqual(try reopened.payload(for: entry.id), payload)
        XCTAssertNil(try Data(contentsOf: url).range(of: Data(original.utf8)))
        guard case .entries(let found, _) = HistorySearch.evaluate(entries, query: "HistoryStore") else {
            return XCTFail("冻结源码应匹配历史查询")
        }
        XCTAssertEqual(found.map(\.id), [entry.id])
    }

    func testNestedTransactions() throws {
        let db = try HistoryDatabase(CoreTestFiles.database())
        try db.exec("CREATE TABLE values_for_test(number INTEGER)")
        try db.transaction {
            try db.exec("INSERT INTO values_for_test VALUES(1)")
            XCTAssertThrowsError(try db.transaction {
                try db.exec("INSERT INTO values_for_test VALUES(2)")
                try db.exec("SELECT missing_column FROM values_for_test")
            })
            try db.transaction { try db.exec("INSERT INTO values_for_test VALUES(3)") }
        }
        XCTAssertThrowsError(try db.transaction {
            try db.transaction { try db.exec("INSERT INTO values_for_test VALUES(4)") }
            try db.exec("SELECT missing_column FROM values_for_test")
        })
        var numbers = [Int32]()
        try db.rows("SELECT number FROM values_for_test ORDER BY number") { numbers.append(sqlite3_column_int($0, 0)) }
        XCTAssertEqual(numbers, [1, 3])
    }

    func testCompatibleExtraColumn() throws {
        let url = try CoreTestFiles.database(), key = SymmetricKey(size: .bits256)
        let original = try CoreTestFiles.source("App")
        let store = try HistoryStore(url: url, key: key)
        let entry = try store.save(.text(original))
        let db = try HistoryDatabase(url)
        try db.exec("ALTER TABLE records ADD COLUMN optional_metadata BLOB")
        try db.exec("CREATE TABLE damaged_records AS SELECT * FROM records WHERE 0")
        let reopened = try HistoryStore(url: url, key: key)
        XCTAssertEqual(try reopened.load().map(\.id), [entry.id])
        XCTAssertEqual(try db.userVersion(), SchemaVersion.current)
    }

    func testRichTextAndUndoRestore() throws {
        let url = try CoreTestFiles.database(), key = SymmetricKey(size: .bits256)
        let store = try HistoryStore(url: url, key: key)
        let plain = try store.save(.text("plain text"))
        let html = Data("<b>rich</b>".utf8)
        let rich = try store.save(.text("rich text", html: html))
        let third = try store.save(.text("third text"))
        try store.addFavorite(plain.id)
        try store.addFavorite(rich.id)
        try store.addFavorite(third.id)

        let reopened = try HistoryStore(url: url, key: key)
        _ = try reopened.load()

        // 撤销删除历史记录并保留原位置与富文本负载
        let deletedHistory = try reopened.deleteForUndo(rich.id, fromFavorites: false)
        XCTAssertNotNil(deletedHistory)
        XCTAssertEqual(reopened.entries.map(\.id), [third.id, plain.id])
        XCTAssertTrue(try reopened.restore(deletedHistory!))
        XCTAssertEqual(reopened.entries.map(\.id), [third.id, rich.id, plain.id])
        XCTAssertEqual(try reopened.payload(for: rich.id), .text("rich text", html: html))

        // 撤销取消收藏并保留原有收藏顺序
        let deletedFavorite = try reopened.deleteForUndo(rich.id, fromFavorites: true)
        XCTAssertNotNil(deletedFavorite)
        XCTAssertEqual(reopened.favorites.map(\.id), [plain.id, third.id])
        XCTAssertTrue(try reopened.restore(deletedFavorite!))
        XCTAssertEqual(reopened.favorites.map(\.id), [plain.id, rich.id, third.id])

        // 仅在历史中的记录放弃撤销后物理清除
        try reopened.removeFavorite(rich.id)
        let finalDelete = try reopened.deleteForUndo(rich.id, fromFavorites: false)
        XCTAssertNotNil(finalDelete)
        try reopened.discardDeleted(finalDelete!)
        let db = try HistoryDatabase(url)
        var count: Int64 = -1
        try db.rows("SELECT COUNT(*) FROM records WHERE id=?", [.text(rich.id)]) {
            count = sqlite3_column_int64($0, 0)
        }
        XCTAssertEqual(count, 0)
    }
}
