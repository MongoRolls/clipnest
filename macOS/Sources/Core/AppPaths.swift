import Foundation

package struct AppPaths {
    package static let bundleIdentifier = "com.clipnest.mac"
    package static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("ClipNest", isDirectory: true)
    }
    package let directory: URL
    package init(directory: URL) { self.directory = directory }
    package var historyDatabase: URL { directory.appendingPathComponent("history.db") }
    package var errorLog: URL { directory.appendingPathComponent("errors.log") }
    package var previousErrorLog: URL { directory.appendingPathComponent("errors.previous.log") }
    package var panelBackground: URL { directory.appendingPathComponent("panel-background.plist") }
    package var instanceLock: URL { directory.appendingPathComponent("instance.lock") }
}

package enum Tuning {
    // 轮询只取稳定的版本。定时器允许少量偏差，休眠期间完全停止。
    package static let pollInterval: TimeInterval = 0.4
    package static let pollAttempts = 3
    package static let shutdownTimeout: TimeInterval = 5
    // 列表、预览和识别分别限制解码尺寸，手动提取可以保留更多细小文字。
    package static let thumbnailMaxPixelSize = 400
    package static let previewMaxPixelSize = 720
    package static let backgroundOCRMaxPixelSize = 2400
    package static let manualOCRMaxPixelSize = 4096
    // 单条和整次查询分别限时，避免一个复杂表达式占用搜索队列过久。
    package static let regexQueryTimeout: TimeInterval = 4
    package static let regexEntryTimeout: TimeInterval = 1
}
