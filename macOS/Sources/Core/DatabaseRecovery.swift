import Darwin
import Foundation

/// 仅在用户确认且实例锁已取得、worker 已释放数据库连接后执行。
package enum DatabaseRecovery {
    private static let suffixes = ["", "-wal", "-shm", "-journal"]
    private static let reopeningKey = "com.clipnest.database-recovery.reopening"

    private struct Journal: Codable {
        let archive: String
        let files: [String]
    }

    package static func canArchive(after error: Error) -> Bool {
        (error as? AppError)?.code == .damagedDatabase
    }

    package static func archiveAndRestart(at url: URL, reopen: () throws -> HistoryStore) throws -> HistoryStore {
        let fs = FileManager.default
        try restoreInterrupted(at: url)
        let directory = url.deletingLastPathComponent()
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let stem = "\(url.deletingPathExtension().lastPathComponent).corrupt-\(stamp)-\(UUID().uuidString)"
        let archive = directory.appendingPathComponent(stem, isDirectory: true)
        let stage = directory.appendingPathComponent(".\(stem).staging", isDirectory: true)
        let marker = journalURL(for: url)
        let files = try existingFamily(at: url)
        guard files.contains("") else { throw AppError(L("未找到可归档的数据库。"), code: .database) }
        let journal = Journal(archive: stem, files: files)
        return try withFileLocks(at: url, files: files) {
            // 先取得独立副本，完整归档可用后才移除原文件。损坏的数据库也无需经过 SQLite 解析。
            try fs.createDirectory(at: stage, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            do {
                for suffix in files {
                    try fs.copyItem(at: member(url, suffix), to: stage.appendingPathComponent(stem + ".db" + suffix))
                }
                try fs.moveItem(at: stage, to: archive)
            } catch let original {
                do { try fs.removeItem(at: stage) }
                catch { throw rollbackError(original, error) }
                throw original
            }
            try PropertyListEncoder().encode(journal).write(to: marker, options: .atomic)
            do {
                for suffix in files { try unlinkFile(member(url, suffix)) }
                // 同步重开回调中的 open 已处于本次恢复事务内。其他启动会先检查磁盘恢复记录。
                let thread = Thread.current.threadDictionary
                thread[reopeningKey] = url.standardizedFileURL.path
                defer { thread.removeObject(forKey: reopeningKey) }
                let store = try reopen()
                try fs.removeItem(at: marker)
                return store
            } catch let original {
                do { try restore(journal, at: url) }
                catch { throw rollbackError(original, error) }
                throw original
            }
        }
    }

    static func restoreInterrupted(at url: URL) throws {
        guard Thread.current.threadDictionary[reopeningKey] as? String != url.standardizedFileURL.path else { return }
        let marker = journalURL(for: url)
        guard FileManager.default.fileExists(atPath: marker.path) else { return }
        let journal = try PropertyListDecoder().decode(Journal.self, from: Data(contentsOf: marker))
        let prefix = url.deletingPathExtension().lastPathComponent + ".corrupt-"
        guard journal.archive.hasPrefix(prefix), !journal.archive.contains("/"), journal.files.contains(""),
              Set(journal.files).isSubset(of: suffixes), Set(journal.files).count == journal.files.count else {
            throw AppError(L("数据库恢复记录无效，原始归档已保留。"), code: .database)
        }
        try withFileLocks(at: url, files: existingFamily(at: url)) { try restore(journal, at: url) }
    }

    private static func restore(_ journal: Journal, at url: URL) throws {
        let fs = FileManager.default
        let directory = url.deletingLastPathComponent()
        let archive = directory.appendingPathComponent(journal.archive, isDirectory: true)
        // 单文件原子替换可反复执行。恢复记录保留到主库、WAL 和日志全部回到原路径之后。
        for suffix in suffixes {
            let target = member(url, suffix)
            if journal.files.contains(suffix) {
                let copy = directory.appendingPathComponent(".\(journal.archive).restoring\(suffix)")
                if fs.fileExists(atPath: copy.path) { try unlinkFile(copy) }
                try fs.copyItem(at: archive.appendingPathComponent(journal.archive + ".db" + suffix), to: copy)
                guard rename(copy.path, target.path) == 0 else { throw posixError() }
            } else if fs.fileExists(atPath: target.path) {
                try unlinkFile(target)
            }
        }
        try fs.removeItem(at: journalURL(for: url))
    }

    private static func withFileLocks<T>(at url: URL, files: [String], _ body: () throws -> T) throws -> T {
        var handles: [Int32] = []
        defer { for handle in handles { close(handle) } }
        for suffix in files {
            let handle = open(member(url, suffix).path, O_RDWR | O_NOFOLLOW | O_CLOEXEC)
            guard handle >= 0 else { throw posixError() }
            handles.append(handle)
            // OFD 锁与 SQLite 的 Unix 字节范围锁冲突，主文件及 WAL 共享内存都须空闲。
            var lock = flock(l_start: 0, l_len: 0, l_pid: 0, l_type: Int16(F_WRLCK), l_whence: Int16(SEEK_SET))
            guard fcntl(handle, F_OFD_SETLK, &lock) == 0 else { throw posixError() }
        }
        return try body()
    }

    private static func existingFamily(at url: URL) throws -> [String] {
        try suffixes.filter { suffix in
            var info = stat()
            if lstat(member(url, suffix).path, &info) != 0 {
                if errno == ENOENT { return false }
                throw posixError()
            }
            guard info.st_mode & S_IFMT == S_IFREG else { throw AppError(L("数据库文件类型无效。"), code: .database) }
            return true
        }
    }

    private static func journalURL(for url: URL) -> URL { member(url, ".recovery.plist") }
    private static func member(_ url: URL, _ suffix: String) -> URL { URL(fileURLWithPath: url.path + suffix) }
    private static func unlinkFile(_ url: URL) throws {
        guard unlink(url.path) == 0 else { throw posixError() }
    }
    private static func posixError() -> NSError { NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
    private static func rollbackError(_ original: Error, _ rollback: Error) -> AppError {
        AppError(L("%@；回滚失败：%@", original.localizedDescription, rollback.localizedDescription), code: .database)
    }
}
