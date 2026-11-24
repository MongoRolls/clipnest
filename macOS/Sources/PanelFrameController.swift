import AppKit
import QuartzCore

@MainActor
final class PanelFrameController {
    private enum Anchor {
        case cursor(PanelPlacement)
        case dragged
    }
    private let window: HistoryWindow
    private var anchor: Anchor?
    private var adjusting = false
    var needsPosition: Bool { !window.isVisible || anchor == nil || !NSApp.isActive }

    init(window: HistoryWindow) { self.window = window }

    func endPresentation() { anchor = nil }

    func begin(at cursor: NSPoint, height: CGFloat) {
        guard let screen = NSScreen.screens.first(where: { NSMouseInRect(cursor, $0.frame, false) }) ?? NSScreen.main else { return }
        anchor = .cursor(PanelPlacement(cursor: cursor, visibleFrame: screen.visibleFrame, height: height))
        resize(to: height)
    }

    func willMove() {
        if !adjusting, anchor != nil { anchor = .dragged }
    }

    func height(for content: PanelContent, extraHeight: CGFloat, failed: Bool) -> CGFloat {
        var height = HistoryLayout.controlsHeight + extraHeight
        if failed { return height + 170 }
        for row in 0..<content.count {
            if height >= HistoryLayout.height { break }
            height += content.rowHeight(at: row)
        }
        return min(HistoryLayout.height, max(window.minSize.height, height))
    }

    func resize(to height: CGFloat) {
        guard let anchor else { return }
        let frame: NSRect
        switch anchor {
        case .cursor(let placement):
            frame = placement.frame(for: NSSize(width: window.frame.width, height: height))
        case .dragged:
            guard window.isVisible, let screen = window.screen else { return }
            frame = PanelPlacement.afterDrag(current: window.frame, height: height, visibleFrame: screen.visibleFrame)
        }
        guard frame != window.frame else { return }
        adjusting = true
        defer { adjusting = false }
        if window.isVisible {
            window.setFrame(frame, display: true)
        } else {
            // 面板尚未显示时同步提交新位置、布局与阴影，避免 orderFront 先闪现旧坐标。
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            window.setFrame(frame, display: false)
            window.layoutIfNeeded()
            window.invalidateShadow()
            CATransaction.commit()
            CATransaction.flush()
        }
    }
}

/// 以面板布局常量填入边距和指针间隔，保持界面层调用方式不变。
extension PanelPlacement {
    init(cursor: NSPoint, visibleFrame: NSRect, height: CGFloat) {
        self.init(cursor: cursor, visibleFrame: visibleFrame, height: height,
                  margin: HistoryLayout.screenMargin, gap: HistoryLayout.cursorGap)
    }

    static func afterDrag(current: NSRect, height: CGFloat, visibleFrame: NSRect) -> NSRect {
        afterDrag(current: current, height: height, visibleFrame: visibleFrame, margin: HistoryLayout.screenMargin)
    }
}
