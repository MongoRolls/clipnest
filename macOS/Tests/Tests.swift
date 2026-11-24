import AppKit
import SQLite3

@main
@MainActor
enum Tests {
    static func expect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        guard try condition() else { throw AppError("验证失败：\(message)") }
    }

    static func rejects(_ message: String, _ action: () throws -> Void) throws {
        do { try action() } catch { return }
        throw AppError("验证失败：\(message)没有拒绝错误输入")
    }

    static func main() throws {
        _ = NSApplication.shared
        let root = TestProject.root
            .appendingPathComponent(".work/macos/tests-\(UUID().uuidString)", isDirectory: true)
        let cases: [(String, @MainActor (URL) throws -> Void)] = [
            ("窗口材质与输入法", WindowAndSettingsTests.windowEvents),
            ("面板定位", WindowAndSettingsTests.placement),
            ("模型与数字快捷键", WindowAndSettingsTests.model),
            ("快捷键录制规则", PanelTests.shortcutRules),
            ("命令名称与别名", PanelTests.commands),
            ("直接粘贴与权限引导", PanelTests.directPasteAndAccessibility),
            ("模糊搜索、来源筛选和正则", SearchFeatureTests.search),
            ("迁移第二版历史数据库", StorageMetadataTests.migration),
            ("迁移第三版历史数据库与加密图片文字", StorageMetadataTests.ocrMigration),
            ("读取冻结的第四版历史数据库", StorageMetadataTests.v4Snapshot),
            ("本地 Vision 文字识别", ImageOCRTests.recognition),
            ("图片文字识别调度", ImageOCRTests.service),
            ("服务观察者与有界退出", ImageOCRTests.serviceLifecycle),
            ("收录时关联来源应用", StorageMetadataTests.capture),
            ("面板背景图片", PanelTests.panelBackground),
            ("原生历史行与背景绘制", HistoryRowTests.render),
            ("中英文单行底栏", HistoryRowTests.footerLayout),
            ("偏好与语言资源", WindowAndSettingsTests.settingsAndLanguage),
            ("切换语言后保留开库诊断", PanelTests.localizedLoadFailure),
            ("暂停与忽略应用", CapturePolicyTests.capture),
            ("调整历史容量", CapturePolicyTests.retention),
            ("历史与收藏", HistoryStoreTests.membership),
            ("真实剪贴板", ClipboardTests.clipboard),
            ("大段富文本", ClipboardTests.largeHTML),
            ("收藏回填与图片", HistoryStoreTests.favoriteCopies),
            ("损坏记录归档", HistoryStoreTests.corruption),
            ("按需读取与字段认证", HistoryStoreTests.fieldAuthentication),
            ("保留旧版数据库", HistoryStoreTests.legacyBackup),
            ("写锁与剪贴板重试", ClipboardTests.lockedCapture),
            ("满额时回填最旧富文本", ClipboardTests.oldestCopy),
            ("图片文字面板交互", PanelTests.imageText(in:)),
            ("原生面板交互", PanelTests.run(in:))
        ]
        let selected: [(String, @MainActor (URL) throws -> Void)]
        if let raw = ProcessInfo.processInfo.environment["CLIPNEST_TEST"]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !raw.isEmpty {
            let filters = raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
            selected = cases.filter { name, _ in filters.contains { name.localizedCaseInsensitiveContains($0) } }
            guard !selected.isEmpty else {
                throw AppError("CLIPNEST_TEST=\(raw) 未匹配到任何用例。可用用例：\(cases.map(\.0).joined(separator: "、"))")
            }
        } else {
            selected = cases
        }
        var failures = [String]()
        for (name, run) in selected {
            let directory = root.appendingPathComponent(name, isDirectory: true)
            let started = ProcessInfo.processInfo.systemUptime
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try autoreleasepool { try run(directory) }
                let elapsed = String(format: "%.2f", ProcessInfo.processInfo.systemUptime - started)
                print("PASS \(name)（\(elapsed) 秒）")
            } catch {
                let elapsed = String(format: "%.2f", ProcessInfo.processInfo.systemUptime - started)
                let failure = "\(name)（\(elapsed) 秒）：\(error.localizedDescription)"
                print("FAIL \(failure)")
                failures.append(failure)
            }
        }
        print("通过 \(selected.count - failures.count)/\(selected.count)，测试目录：\(root.path)")
        if !failures.isEmpty { throw AppError(failures.joined(separator: "\n")) }
    }

    static func icon() throws -> Payload {
        let data = try Data(contentsOf: TestProject.icon)
        let (width, height) = try ClipImage.size(data)
        return .image(png: data, width: width, height: height)
    }

    static func richText() throws -> Payload {
        let string = try TestProject.source("Models")
        let document = NSAttributedString(string: string, attributes: [.font: NSFont.boldSystemFont(ofSize: 13)])
        let range = NSRange(location: 0, length: document.length)
        let html = try document.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.html])
        let rtf = try document.data(from: range, documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        return .text(string, html: html, rtf: rtf)
    }

    static func board() -> NSPasteboard {
        NSPasteboard(name: .init("com.clipnest.tests.\(UUID().uuidString)"))
    }

    static func number(_ db: HistoryDatabase, _ sql: String, _ values: [HistoryDatabase.Value] = []) throws -> Int {
        var result: Int?
        try db.rows(sql, values) { result = Int(sqlite3_column_int64($0, 0)) }
        guard let result else { throw AppError("查询未返回预期的数值：\(sql)") }
        return result
    }
}
