import Foundation

typealias ErrorReporter = @MainActor (String, Error) -> Void

struct ErrorLog {
    let directory: URL

    func report(_ action: String, _ error: Error) {
        do { try append(action, error) }
        catch let logError {
            let original = error as NSError, failure = logError as NSError
            NSLog("%@ %@ %ld; errors.log: %@ %ld", action, original.domain, original.code, failure.domain, failure.code)
        }
    }

    func append(_ action: String, _ error: Error) throws {
        let files = FileManager.default
        let paths = AppPaths(directory: directory)
        let url = paths.errorLog
        if files.fileExists(atPath: url.path) {
            let attributes = try files.attributesOfItem(atPath: url.path)
            if (attributes[.size] as? Int ?? 0) > 1024 * 1024 {
                let previous = paths.previousErrorLog
                if files.fileExists(atPath: previous.path) { try files.removeItem(at: previous) }
                try files.moveItem(at: url, to: previous)
            }
        }
        if !files.fileExists(atPath: url.path) { try Data().write(to: url) }
        let handle = try FileHandle(forWritingTo: url)
        do {
            try handle.seekToEnd()
            // 只记录操作及错误类型和代码，避免文件路径或正文进入日志。
            let nsError = error as NSError
            try handle.write(contentsOf: Data("\(Date()) \(action) \(nsError.domain) \(nsError.code)\n".utf8))
        } catch let writeError {
            do { try handle.close() }
            catch { throw AppError(writeError.localizedDescription + "\n" + L("关闭错误日志失败：%@", error.localizedDescription)) }
            throw writeError
        }
        try handle.close()
    }
}
