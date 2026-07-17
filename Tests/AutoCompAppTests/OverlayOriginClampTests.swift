import CoreGraphics
@testable import AutoCompApp
import XCTest

final class OverlayOriginClampTests: XCTestCase {
    func testOriginInsideVisibleFrameIsUnchanged() {
        let visibleFrame = CGRect(x: 100, y: 50, width: 800, height: 600)

        let result = visibleFrame.clampingOrigin(
            CGPoint(x: 240, y: 180),
            panelSize: CGSize(width: 300, height: 120)
        )

        XCTAssertEqual(result.origin, CGPoint(x: 240, y: 180))
        XCTAssertFalse(result.wasClamped)
    }

    func testOriginClampsWithinNegativeOriginDisplay() {
        let visibleFrame = CGRect(x: -1920, y: -100, width: 1920, height: 1080)

        let result = visibleFrame.clampingOrigin(
            CGPoint(x: -100, y: 950),
            panelSize: CGSize(width: 300, height: 120)
        )

        XCTAssertEqual(result.origin, CGPoint(x: -300, y: 860))
        XCTAssertTrue(result.wasClamped)
    }

    func testOversizedPanelAnchorsAtVisibleFrameMinimum() {
        let visibleFrame = CGRect(x: 100, y: 50, width: 300, height: 200)

        let result = visibleFrame.clampingOrigin(
            CGPoint(x: 250, y: 125),
            panelSize: CGSize(width: 500, height: 400)
        )

        XCTAssertEqual(result.origin, CGPoint(x: 100, y: 50))
        XCTAssertTrue(result.wasClamped)
    }
}
