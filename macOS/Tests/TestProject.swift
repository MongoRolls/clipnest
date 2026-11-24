import Foundation

enum TestProject {
    static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let resources = root.appendingPathComponent("macOS/Resources", isDirectory: true)
    static let icon = resources.appendingPathComponent("ClipNestIcon.png")
    static let fixtures = root.appendingPathComponent("macOS/Tests/Fixtures", isDirectory: true)

    static func source(_ name: String) throws -> String {
        try String(contentsOf: fixtures.appendingPathComponent(name + ".txt"), encoding: .utf8)
    }
}
