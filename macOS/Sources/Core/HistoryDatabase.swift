import Foundation
import SQLite3

// 所有语句和绑定值的生命周期都在调用闭包内结束。
final class HistoryDatabase {
    enum Value { case text(String), integer(Int64), real(Double), blob(NSData), null }
    private var handle: OpaquePointer?
    private var transactionDepth = 0
    private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(_ url: URL) throws {
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &handle, flags, nil) == SQLITE_OK else { throw failure(L("打开数据库")) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        try exec("PRAGMA busy_timeout=3000; PRAGMA secure_delete=ON")
    }

    deinit { sqlite3_close(handle) }
    func close() throws {
        guard sqlite3_close(handle) == SQLITE_OK else { throw failure(L("关闭数据库")) }
        handle = nil
    }
    var changes: Int32 { sqlite3_changes(handle) }

    func userVersion() throws -> Int32 {
        Int32(try int64("PRAGMA user_version") ?? 0)
    }

    func exists(_ sql: String, _ values: [Value] = []) throws -> Bool {
        var found = false
        try rows(sql, values) { _ in found = true }
        return found
    }

    func int64(_ sql: String, _ values: [Value] = []) throws -> Int64? {
        var result: Int64?
        try rows(sql, values) { result = sqlite3_column_int64($0, 0) }
        return result
    }

    private func failure(_ operation: String) -> AppError {
        let code = sqlite3_errcode(handle)
        let damaged = (code & 0xff) == SQLITE_CORRUPT || (code & 0xff) == SQLITE_NOTADB
        return AppError(L("%@失败：%@（%d）。", operation, String(cString: sqlite3_errmsg(handle)), code),
                        code: damaged ? .damagedDatabase : .database)
    }
    func configureIncrementalVacuum() throws {
        guard (try int64("PRAGMA auto_vacuum") ?? 0) != 2 else { return }
        try exec("PRAGMA auto_vacuum=INCREMENTAL")
        // 仅在已有数据页且尚未启用增量回收时执行一次 VACUUM 使其生效。
        if (try int64("PRAGMA page_count") ?? 0) > 0 { try exec("VACUUM") }
    }
    func reclaimFreePages(maxPages: Int = 256) {
        guard (try? int64("PRAGMA freelist_count") ?? 0) ?? 0 > 0 else { return }
        try? exec("PRAGMA incremental_vacuum(\(maxPages))")
    }
    func exec(_ sql: String) throws {
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw failure(L("数据库操作")) }
    }
    func rows(_ sql: String, _ values: [Value] = [], _ read: (OpaquePointer) throws -> Void) throws {
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &prepared, nil) == SQLITE_OK, let stmt = prepared else {
            throw failure(L("准备数据库操作"))
        }
        // 密文绑定使用 NSData 的稳定地址，整个 values 数组保留到语句释放后。
        try withExtendedLifetime(values) {
            defer { sqlite3_finalize(stmt) }
            for (offset, value) in values.enumerated() {
                let index = Int32(offset + 1)
                let status: Int32
                switch value {
                case .text(let string): status = sqlite3_bind_text(stmt, index, string, -1, transient)
                case .integer(let number): status = sqlite3_bind_int64(stmt, index, number)
                case .real(let number): status = sqlite3_bind_double(stmt, index, number)
                case .blob(let bytes): status = sqlite3_bind_blob(stmt, index, bytes.bytes, Int32(bytes.length), nil)
                case .null: status = sqlite3_bind_null(stmt, index)
                }
                guard status == SQLITE_OK else { throw failure(L("绑定数据库字段")) }
            }
            while true {
                switch sqlite3_step(stmt) {
                case SQLITE_ROW: try autoreleasepool { try read(stmt) }
                case SQLITE_DONE: return
                default: throw failure(L("执行数据库操作"))
                }
            }
        }
    }
    func write(_ sql: String, _ values: [Value] = []) throws {
        try rows(sql, values) { _ in throw AppError(L("数据库写入意外返回了记录。")) }
    }
    func transaction<T>(_ body: () throws -> T) throws -> T {
        let outermost = sqlite3_get_autocommit(handle) != 0
        let point = "clipnest_tx_\(transactionDepth)"
        try exec(outermost ? "BEGIN IMMEDIATE" : "SAVEPOINT \(point)")
        transactionDepth += 1
        defer { transactionDepth -= 1 }
        do {
            let result = try body()
            try exec(outermost ? "COMMIT" : "RELEASE SAVEPOINT \(point)")
            return result
        } catch let original {
            do { try exec(outermost ? "ROLLBACK" : "ROLLBACK TO SAVEPOINT \(point); RELEASE SAVEPOINT \(point)") }
            catch { throw AppError(L("%@；回滚失败：%@", original.localizedDescription, error.localizedDescription)) }
            throw original
        }
    }
    static func open(_ url: URL) throws -> HistoryDatabase {
        let files = FileManager.default
        try files.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                  attributes: [.posixPermissions: 0o700])
        try DatabaseRecovery.restoreInterrupted(at: url)
        guard files.fileExists(atPath: url.path) else { return try HistoryDatabase(url) }
        let db = try HistoryDatabase(url)
        let version = try db.userVersion()
        if SchemaVersion.supports(version) { return db }

        // SQLite 先恢复热日志并把 WAL 合并进主文件，再关闭连接并改名。
        try db.rows("PRAGMA journal_mode=DELETE") { stmt in
            guard let mode = sqlite3_column_text(stmt, 0), String(cString: mode).lowercased() == "delete" else {
                throw AppError(L("无法合并旧数据库日志，旧文件已保留。"))
            }
        }
        try db.close()
        for suffix in ["-wal", "-shm", "-journal"] where files.fileExists(atPath: url.path + suffix) {
            throw AppError(L("旧库关闭后仍存在 %@ 文件，无法安全备份。请关闭其他数据库连接后重试。", suffix))
        }
        let base = url.deletingPathExtension().appendingPathExtension("v1")
        var backup = base.appendingPathExtension("db")
        var suffix = 1
        while [backup.path, backup.path + "-wal", backup.path + "-shm", backup.path + "-journal"].contains(where: files.fileExists(atPath:)) {
            backup = base.appendingPathExtension(String(suffix)).appendingPathExtension("db")
            suffix += 1
        }
        try files.moveItem(at: url, to: backup)
        return try HistoryDatabase(url)
    }
}
