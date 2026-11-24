import Foundation

/// 同一次展示只选一次屏幕和方向，搜索和异步加载沿指针旁的同一条边伸缩。
/// 屏幕边距和指针间隔由界面层传入，几何计算不依赖窗口，便于无窗口测试。
package struct PanelPlacement {
    private let available: CGRect
    private let cursorX: CGFloat
    private let edgeY: CGFloat
    private let above: Bool

    package init(cursor: CGPoint, visibleFrame: CGRect, height: CGFloat, margin: CGFloat, gap: CGFloat) {
        available = visibleFrame.insetBy(dx: margin, dy: margin)
        cursorX = cursor.x
        let belowTop = min(available.maxY, max(available.minY, cursor.y - gap))
        let aboveBottom = min(available.maxY, max(available.minY, cursor.y + gap))
        let belowSpace = belowTop - available.minY
        let aboveSpace = available.maxY - aboveBottom
        above = belowSpace < height && aboveSpace > belowSpace
        edgeY = above ? aboveBottom : belowTop
    }

    package func frame(for size: CGSize) -> CGRect {
        let width = min(size.width, available.width)
        let height = min(size.height, above ? available.maxY - edgeY : edgeY - available.minY)
        let x = min(max(cursorX, available.minX), available.maxX - width)
        return CGRect(x: x, y: above ? edgeY : edgeY - height, width: width, height: height)
    }

    package static func afterDrag(current: CGRect, height: CGFloat, visibleFrame: CGRect, margin: CGFloat) -> CGRect {
        let available = visibleFrame.insetBy(dx: margin, dy: margin)
        let width = min(current.width, available.width)
        let height = min(height, available.height)
        // 拖动后的窗口以自己的上边缘为准，靠近屏幕底部时向上让出空间。
        let x = min(max(current.minX, available.minX), available.maxX - width)
        let y = min(max(current.maxY - height, available.minY), available.maxY - height)
        return CGRect(x: x, y: y, width: width, height: height)
    }
}
