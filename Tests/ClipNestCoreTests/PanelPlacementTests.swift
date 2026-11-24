import CoreGraphics
import Foundation
import XCTest
@testable import ClipNestCore

final class PanelPlacementTests: XCTestCase {
    private let margin: CGFloat = 8
    private let gap: CGFloat = 12

    func testSecondaryScreenBelowAboveAndExpansion() {
        let visible = CGRect(x: -1440, y: 25, width: 1440, height: 875)
        let area = visible.insetBy(dx: margin, dy: margin)
        let full = CGSize(width: 460, height: 620)
        let short = CGSize(width: 460, height: 160)

        let cursor = CGPoint(x: -900, y: 800)
        let below = PanelPlacement(cursor: cursor, visibleFrame: visible, height: full.height, margin: margin, gap: gap)
        for size in [full, short, full] {
            let frame = below.frame(for: size)
            XCTAssertEqual(frame.origin.x, cursor.x)
            XCTAssertEqual(frame.maxY, cursor.y - gap)
            XCTAssertEqual(frame.size, size)
        }

        let bottom = CGPoint(x: -60, y: 250)
        let above = PanelPlacement(cursor: bottom, visibleFrame: visible, height: full.height, margin: margin, gap: gap)
        for size in [full, short, full] {
            let frame = above.frame(for: size)
            XCTAssertEqual(frame.minY, bottom.y + gap)
            XCTAssertEqual(frame.maxX, area.maxX)
            XCTAssertEqual(frame.size, size)
        }

        let loading = PanelPlacement(cursor: bottom, visibleFrame: visible, height: short.height, margin: margin, gap: gap)
        let expanded = loading.frame(for: full)
        XCTAssertEqual(expanded.maxY, bottom.y - gap)
        XCTAssertEqual(expanded.minY, area.minY)
        XCTAssertLessThan(expanded.height, full.height)
    }

    func testSmallScreenClampingAndAfterDrag() {
        let visible = CGRect(x: -1440, y: 25, width: 1440, height: 875)
        let area = visible.insetBy(dx: margin, dy: margin)
        let full = CGSize(width: 460, height: 620)
        let short = CGSize(width: 460, height: 160)

        let small = CGRect(x: 0, y: -400, width: 400, height: 300)
        let smallArea = small.insetBy(dx: margin, dy: margin)
        for point in [
            CGPoint(x: small.minX, y: small.minY),
            CGPoint(x: small.maxX, y: small.maxY),
            CGPoint(x: small.midX, y: small.midY)
        ] {
            let frame = PanelPlacement(cursor: point, visibleFrame: small, height: full.height, margin: margin, gap: gap)
                .frame(for: full)
            XCTAssertTrue(smallArea.contains(frame))
            XCTAssertEqual(frame.width, smallArea.width)
            XCTAssertGreaterThan(frame.height, 0)
            XCTAssertTrue(frame.maxY <= point.y - gap || frame.minY >= point.y + gap)
        }

        let dragged = CGRect(x: -1300, y: 280, width: full.width, height: 350)
        let filtered = PanelPlacement.afterDrag(current: dragged, height: short.height, visibleFrame: visible, margin: margin)
        XCTAssertEqual(filtered.minX, dragged.minX)
        XCTAssertEqual(filtered.maxY, dragged.maxY)
        XCTAssertEqual(filtered.height, short.height)

        let restored = PanelPlacement.afterDrag(current: filtered, height: full.height, visibleFrame: visible, margin: margin)
        XCTAssertEqual(restored.minX, dragged.minX)
        XCTAssertTrue(area.contains(restored))
        XCTAssertEqual(restored.minY, area.minY)
    }
}
