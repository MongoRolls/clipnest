import CryptoKit
import Darwin
import Foundation
import XCTest
@testable import ClipNestCore

final class DatabaseRecoveryTests: XCTestCase {
    private let fs = FileManager.default
    private let family = ["", "-wal", "-shm", "-journal"]
    private func member(_ url: URL, _ suffix: String) -> URL { URL(fileURLWithPath: url.path + suffix) }
    private func contents(at url: URL) throws -> [String: Data] {
        var result = [String: Data]()
        for suffix in family where fs.fileExists(atPath: member(url, suffix).path) {
            result[suffix] = try Data(contentsOf: member(url, suffix))
        }
        return result
    }

    func testUnopenableDatabase() throws {
        let url = try CoreTestFiles.database(), key = SymmetricKey(size: .bits256)
        _ = try HistoryStore(url: url, key: key)
        // 覆写真实 SQLite 文件的签名，验证引擎返回 NOTADB 时仍能按原字节归档。
        let file = try FileHandle(forWritingTo: url)
        try file.write(contentsOf: Data("ClipNest History".utf8))
        try file.close()
        XCTAssertThrowsError(try HistoryStore(url: url, key: key)) { XCTAssertTrue(DatabaseRecovery.canArchive(after: $0)) }
        let original = try Data(contentsOf: url)
        let next = try DatabaseRecovery.archiveAndRestart(at: url) {
            let store = try HistoryStore(url: url, key: key)
            try store.load()
            return store
        }
        XCTAssertTrue(next.entries.isEmpty)
        let archives = try fs.contentsOfDirectory(at: url.deletingLastPathComponent(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("history.corrupt-") }
        XCTAssertEqual(archives.count, 1)
        let archive = try XCTUnwrap(archives.first)
        XCTAssertEqual(try Data(contentsOf: archive.appendingPathComponent(archive.lastPathComponent + ".db")), original)
    }

    func testRestartFailureRestoresCommittedWAL() throws {
        let original = try CoreTestFiles.database(), target = try CoreTestFiles.database(), key = SymmetricKey(size: .bits256)
        let data = try CoreTestFiles.source("HistoryStore")
        let entryID = try autoreleasepool {
            let db = try HistoryDatabase(original)
            try db.exec("PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0")
            // 在开启 WAL 的独立测试连接上写入实际表结构和密文。
            try SchemaMigrator.apply(to: db)
            let store = try HistoryStore(url: original, key: key)
            let id = try store.save(.text(data)).id
            let bytes = try contents(at: original)
            XCTAssertNotNil(bytes["-wal"])
            XCTAssertNotNil(bytes["-shm"])
            for (suffix, file) in bytes { try file.write(to: member(target, suffix)) }
            return id
        }
        let before = try contents(at: target)
        XCTAssertThrowsError(try DatabaseRecovery.archiveAndRestart(at: target) {
            let fresh = try HistoryStore(url: target, key: key)
            try fresh.save(.text(data))
            let wrongKey = try HistoryStore(url: target, key: SymmetricKey(size: .bits256))
            try wrongKey.load()
            return wrongKey
        }) { XCTAssertTrue(DatabaseRecovery.canArchive(after: $0)) }
        XCTAssertEqual(try contents(at: target), before)
        XCTAssertEqual(try HistoryStore(url: target, key: key).load().map(\.id), [entryID])
    }

    func testBusyDatabaseCannotBeArchived() throws {
        let url = try CoreTestFiles.database(), key = SymmetricKey(size: .bits256)
        let store = try HistoryStore(url: url, key: key)
        let db = try HistoryDatabase(url)
        try db.exec("BEGIN IMMEDIATE")
        defer { try? db.exec("ROLLBACK") }
        XCTAssertThrowsError(try store.save(.text(CoreTestFiles.source("App")))) {
            XCTAssertFalse(DatabaseRecovery.canArchive(after: $0))
        }
        XCTAssertThrowsError(try DatabaseRecovery.archiveAndRestart(at: url) {
            XCTFail("持有写锁时不能开始重开")
            return store
        })
        XCTAssertFalse(fs.fileExists(atPath: member(url, ".recovery.plist").path))
    }

    func testInterruptedRestartRestoresBeforeOpening() throws {
        let childKey = "CLIPNEST_RECOVERY_TEST_FILE"
        if let path = ProcessInfo.processInfo.environment[childKey] {
            let url = URL(fileURLWithPath: path).standardizedFileURL
            guard url.deletingLastPathComponent().deletingLastPathComponent().path == CoreTestFiles.directory.standardizedFileURL.path
                    && url.lastPathComponent == "history.db" else { return XCTFail("子进程仅可访问本用例的独立数据库") }
            _ = try DatabaseRecovery.archiveAndRestart(at: url) {
                let store = try HistoryStore(url: url, key: SymmetricKey(size: .bits256))
                try store.save(.text(CoreTestFiles.source("Models")))
                // 中止测试子进程，不执行 defer、回滚或正常的数据库关闭流程。
                _exit(73)
            }
            return XCTFail("子进程必须在写入新库后中断")
        }
        let url = try CoreTestFiles.database(), key = SymmetricKey(size: .bits256)
        let payload = Payload.text(try CoreTestFiles.source("HistorySearch"))
        let entryID = try HistoryStore(url: url, key: key).save(payload).id
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        child.arguments = ["xctest", "-XCTest", "ClipNestCoreTests.DatabaseRecoveryTests/testInterruptedRestartRestoresBeforeOpening",
                           Bundle(for: type(of: self)).bundleURL.path]
        child.environment = ["PATH": "/usr/bin:/bin", childKey: url.path]
        try child.run()
        child.waitUntilExit()
        XCTAssertEqual(child.terminationStatus, 73)
        XCTAssertTrue(fs.fileExists(atPath: member(url, ".recovery.plist").path))
        let restored = try HistoryStore(url: url, key: key)
        XCTAssertEqual(try restored.load().map(\.id), [entryID])
        XCTAssertEqual(try restored.payload(for: entryID), payload)
        XCTAssertFalse(fs.fileExists(atPath: member(url, ".recovery.plist").path))
    }
}
