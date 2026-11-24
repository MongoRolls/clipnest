import Foundation

enum CoreTestFiles {
    static let project = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let directory = project.appendingPathComponent(".work/macos/core-tests", isDirectory: true)
    static func source(_ name: String) throws -> String {
        try String(contentsOf: project.appendingPathComponent("macOS/Tests/Fixtures/\(name).txt"), encoding: .utf8)
    }
    static func database() throws -> URL {
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("history.db")
    }
}
