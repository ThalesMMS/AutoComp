import AppKit
@testable import AutoCompApp
import XCTest

final class VisibleTextLineEstimatorTests: XCTestCase {
    func testEmptyAndExplicitNewlineUseOnlyCurrentLogicalLine() {
        let font = NSFont.monospacedSystemFont(ofSize: 14, weight: .regular)

        XCTAssertEqual(
            VisibleTextLineEstimator.estimate(in: "", font: font, maxLineWidth: 80),
            VisibleTextLineEstimate(width: 0, lineIndex: 0)
        )
        XCTAssertEqual(
            VisibleTextLineEstimator.estimate(in: "a very long prior line\nabc", font: font, maxLineWidth: 80),
            VisibleTextLineEstimator.estimate(in: "abc", font: font, maxLineWidth: 80)
        )
    }

    func testLineBreakLayoutWrapsLongLineAndPreservesUnicodeClusters() {
        let font = NSFont.systemFont(ofSize: 14)
        let singleEmojiWidth = measuredWidth("👨‍👩‍👧‍👦", font: font)
        let estimate = VisibleTextLineEstimator.estimate(
            in: "👨‍👩‍👧‍👦👨‍👩‍👧‍👦👨‍👩‍👧‍👦",
            font: font,
            maxLineWidth: singleEmojiWidth + 0.5
        )

        XCTAssertEqual(estimate.lineIndex, 2)
        XCTAssertEqual(estimate.width, singleEmojiWidth)
    }

    func testSingleLineWidthIncludesTrailingWhitespace() {
        let font = NSFont.systemFont(ofSize: 14)
        let text = "caret after space "

        let estimate = VisibleTextLineEstimator.estimate(
            in: text,
            font: font,
            maxLineWidth: 1_000
        )

        XCTAssertEqual(estimate.lineIndex, 0)
        XCTAssertEqual(estimate.width, measuredWidth(text, font: font))
    }

    func testBothGeometryConsumersUseSharedLinearEstimator() throws {
        let axSource = try sourceFile("Sources/AutoCompApp/Services/AXTextGeometryResolver.swift")
        let inlineSource = try sourceFile("Sources/AutoCompApp/Services/Overlay/Geometry/InlinePreviewGeometry.swift")
        let estimatorSource = try sourceFile("Sources/AutoCompApp/Services/VisibleTextLineEstimator.swift")

        XCTAssertTrue(axSource.contains("VisibleTextLineEstimator.estimate("))
        XCTAssertTrue(inlineSource.contains("VisibleTextLineEstimator.estimate("))
        XCTAssertFalse(axSource.contains("currentLine + String(character)"))
        XCTAssertFalse(inlineSource.contains("currentLine + String(character)"))
        XCTAssertTrue(estimatorSource.contains("CTTypesetterSuggestLineBreak"))
    }

    private func measuredWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}
