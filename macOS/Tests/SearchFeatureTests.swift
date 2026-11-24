import Foundation

@MainActor
enum SearchFeatureTests {
    static func search(_ directory: URL) throws {
        func entry(_ text: String, source: String? = nil) -> Entry {
            Entry(id: HistoryStore.fingerprint(.text(text)), date: Date(), content: .text(text), sourceAppBundleID: source)
        }
        let controller = TestProject.root.appendingPathComponent("macOS/Sources/HistoryPanelController.swift").deletingPathExtension().lastPathComponent
        let target = entry("📋 " + controller, source: "com.apple.finder")
        let chinese = entry("剪贴板历史")
        let exact = entry("hpc")
        let red = entry("#1E1E1E")
        let views = entry(try TestProject.source("HistoryViews"))
        let app = entry(try TestProject.source("App"))
        let position = entry(try TestProject.source("PopupPosition"))
        let entries = [target, chinese, exact, red, views, app, position]
        func result(_ query: String, in list: [Entry]? = nil) throws -> ([String], [String: [NSRange]]) {
            guard case let .entries(matches, ranges) = HistorySearch.evaluate(list ?? entries, query: query) else {
                throw AppError("预期查询返回记录：\(query)")
            }
            return (matches.map(\.id), ranges)
        }

        let fuzzy = try result("hpc", in: [target, exact])
        try Tests.expect(fuzzy.0 == [exact.id, target.id] &&
            fuzzy.1[target.id] == [NSRange(location: 3, length: 1), NSRange(location: 10, length: 1), NSRange(location: 15, length: 1)],
            "精确结果优先且驼峰高亮使用 UTF-16 位置")
        let clipboardAccess = entry(String(describing: ClipboardAccess.self))
        let capturePolicyTests = entry(String(describing: CapturePolicyTests.self))
        try Tests.expect(try result("ca", in: [clipboardAccess]).1[clipboardAccess.id] ==
            [NSRange(location: 0, length: 1), NSRange(location: 9, length: 1)], "CA 优先匹配 ClipboardAccess 的 C 和大写 A")
        try Tests.expect(try result("cpt", in: [capturePolicyTests]).1[capturePolicyTests.id] ==
            [NSRange(location: 0, length: 1), NSRange(location: 7, length: 1), NSRange(location: 13, length: 1)],
            "CPT 匹配 CapturePolicyTests 中三个单词的首字母")
        try Tests.expect(try result("剪历", in: [chinese]).1[chinese.id] == [NSRange(location: 0, length: 1), NSRange(location: 3, length: 1)], "中文短词高亮")
        try Tests.expect(try result("popupPosition", in: [app, views, position]).0 == [position.id, app.id], "长源码中的精确命中优先且模糊匹配不跨行")
        try Tests.expect(try result("cornerRadius NSGlassEffectView", in: [app, views]).0 == [views.id], "多词检索完整正文")
        try Tests.expect(try result("type:text @访达 hpc").0 == [target.id] &&
            result("@com.apple.Finder").0 == [target.id], "组合筛选同时匹配来源中文名和 Bundle ID")
        try Tests.expect(try result("#1e1e1e").0 == [red.id] && result("\\#1e1e1e").0 == [red.id], "井号按正文字符检索")
        try Tests.expect(try result("类型:文本").0 == entries.map(\.id), "仅筛选时维持原顺序")
        let icon = try Tests.icon(), pictureID = HistoryStore.fingerprint(icon)
        guard case let .image(_, width, _) = icon else { throw AppError("预期图标为图片。") }
        let picture = Entry(id: pictureID, date: Date(), content: icon.content, sourceAppBundleID: "com.apple.finder",
                            ocrText: "\(controller) 图片 Image \(width)\nERROR-2026")
        for query in ["PanelController", "hpc", "/^ERROR-\\d+/m", "type:image @访达 hpc",
                      "图片", "image", "\(width)", "img"] {
            let (ids, highlights) = try result(query, in: [picture])
            try Tests.expect(ids == [pictureID] && highlights.isEmpty, "图中检索命中且没有不可见的文字高亮：\(query)")
        }
        try Tests.expect(try result("type:text hpc", in: [picture]).0.isEmpty, "文本筛选排除含 OCR 文字的图片")
        let repeated = entry("Clip clip CLIP")
        let allRanges = [NSRange(location: 0, length: 4), NSRange(location: 5, length: 4), NSRange(location: 10, length: 4)]
        try Tests.expect(try result("clip", in: [repeated]).1[repeated.id] == allRanges &&
            result("/clip/i", in: [repeated]).1[repeated.id] == allRanges, "精确与正则均高亮全部命中")
        try Tests.expect(try result("/PanelC", in: [target]).0 == [target.id] &&
            result("/^enum.*CaseIterable/ms", in: [position]).0 == [position.id], "未闭合正则与多行修饰符")
        let multiline = entry("import AppKit\nfunc openPanel() {}")
        try Tests.expect(try result("/^func/m", in: [multiline]).1[multiline.id] == [NSRange(location: 14, length: 4)],
                         "原文第二行的行首匹配映射到单行预览")
        let wholeSource = try result("/.+/s", in: [position])
        try Tests.expect(wholeSource.1[position.id] == [NSRange(location: 0, length: 90), NSRange(location: 91, length: 90)],
                         "整篇正文的匹配只高亮首尾真实字符")
        let path = TestProject.root.appendingPathComponent("macOS/Sources/Core/Models.swift").path
        let file = Entry(id: HistoryStore.fingerprint(.files([path])), date: Date(), content: .files([path]))
        try Tests.expect(try result("/Core\\/Models/", in: [file]).1[file.id] == [NSRange(location: 0, length: 6)],
                         "目录与文件名的跨段匹配只高亮可见文件名")
        // 用冻结源码跑真实 ICU 匹配，分别验证用户换词及超时均能终止一次长时间扫描。
        let expensiveQuery = "/^(.+)+未命中的函数名$/s"
        let started = ProcessInfo.processInfo.systemUptime
        if case .regexTimedOut = HistorySearch.evaluate([app], query: expensiveQuery) {} else { throw AppError("超时正则未终止") }
        try Tests.expect(ProcessInfo.processInfo.systemUptime - started < 4, "单条记录的正则时间预算")
        let cancelAt = ProcessInfo.processInfo.systemUptime + 0.02
        if case .entries = HistorySearch.evaluate([app], query: expensiveQuery, cancelled: {
            ProcessInfo.processInfo.systemUptime >= cancelAt
        }) {} else { throw AppError("已取消的正则仍占用搜索队列") }
        try Tests.expect(try result("popupPosition", in: [app]).0 == [app.id], "终止正则后继续搜索")
        if case .invalidRegex = HistorySearch.evaluate(entries, query: "/[") {} else { throw AppError("无效正则未提示") }
        if case .invalidRegex = HistorySearch.evaluate(entries, query: "/clip/z") {} else { throw AppError("无效正则修饰符未提示") }
        if case .commands("pause") = HistorySearch.evaluate(entries, query: ">pause") {} else { throw AppError("未切换命令查询") }
    }
}
