import Foundation

/// 管理剪贴板收录的暂停状态、忽略应用、版本跳过与来源归属，不直接访问系统剪贴板。
package struct CapturePolicy {
    package struct Decision: Equatable {
        package let skip: Bool
        package let sourceApp: String?
    }

    private let ownBundleID: String?
    package private(set) var paused = false
    package private(set) var ignoredBundleIDs = Set<String>()
    private var skipThrough: Int?
    private var frontmostBundleID: String?
    private var observedSource: (sequence: Int, bundleID: String?)?

    package init(ownBundleID: String? = nil) {
        self.ownBundleID = ownBundleID
    }

    package mutating func updateFrontmost(_ bundleID: String?) {
        frontmostBundleID = bundleID
    }

    package mutating func updatePolicy(paused: Bool, ignoredBundleIDs: Set<String>,
                                       frontmostBundleID: String? = nil, sequence: Int) {
        if let frontmostBundleID { self.frontmostBundleID = frontmostBundleID }
        let activeBundle = self.frontmostBundleID
        // 恢复时也标记当前版本，避免补录两次轮询之间最后复制的内容。
        if self.paused || paused || activeBundle.map({ self.ignoredBundleIDs.contains($0) || ignoredBundleIDs.contains($0) }) == true {
            skipThrough = max(skipThrough ?? sequence, sequence)
        }
        self.paused = paused
        self.ignoredBundleIDs = ignoredBundleIDs
    }

    package mutating func observeSource(_ bundleID: String?, sequence: Int) {
        if let bundleID { frontmostBundleID = bundleID }
        if observedSource?.sequence != sequence {
            // 第一次看到这一版剪贴板时记下前台应用，后台读取时用户可能已切换窗口。
            observedSource = (sequence, bundleID)
        }
        if paused || bundleID.map(ignoredBundleIDs.contains) == true {
            skipThrough = max(skipThrough ?? sequence, sequence)
        }
    }

    package mutating func decision(for sequence: Int) -> Decision {
        if paused || frontmostBundleID.map(ignoredBundleIDs.contains) == true {
            skipThrough = max(skipThrough ?? sequence, sequence)
        }
        let source = observedSource?.sequence == sequence ? observedSource?.bundleID : frontmostBundleID
        return Decision(skip: skipThrough.map { sequence <= $0 } ?? false,
                        sourceApp: source == ownBundleID ? nil : source)
    }
}
