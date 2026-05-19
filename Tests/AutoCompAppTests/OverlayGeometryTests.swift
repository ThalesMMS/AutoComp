import AutoCompCore
@testable import AutoCompApp
import XCTest

final class OverlayGeometryTests: XCTestCase {
    func testFineCaretAnchorsInlinePreviewImmediatelyAfterCursor() {
        let layout = InlinePreviewGeometry.layout(
            context: textContext(
                selectedRange: NSRange(location: 12, length: 0),
                caretRect: CGRect(x: 100, y: 20, width: 2, height: 20),
                focusedElementRect: CGRect(x: 0, y: 0, width: 500, height: 120)
            ),
            contentSize: NSSize(width: 200, height: 18),
            screenFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        )

        XCTAssertEqual(layout?.origin.x, 103)
        XCTAssertGreaterThan(layout?.origin.y ?? 0, 950)
    }

    func testWideAccessibilityCaretUsesPreviousGlyphInsertionPoint() {
        let layout = InlinePreviewGeometry.layout(
            context: textContext(
                selectedRange: NSRange(location: 12, length: 0),
                caretRect: CGRect(x: 420, y: 500, width: 120, height: 24),
                focusedElementRect: CGRect(x: 300, y: 460, width: 300, height: 100),
                previousGlyphRect: CGRect(x: 408, y: 500, width: 11, height: 24)
            ),
            contentSize: NSSize(width: 240, height: 20),
            screenFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        )

        XCTAssertEqual(layout?.origin.x, 420)
    }

    func testWideAccessibilityCaretCanUseLeadingInsertionPointAsLastFallback() {
        let layout = InlinePreviewGeometry.layout(
            context: textContext(
                selectedRange: NSRange(location: 12, length: 0),
                caretRect: CGRect(x: 420, y: 500, width: 120, height: 24),
                focusedElementRect: CGRect(x: 300, y: 460, width: 300, height: 100)
            ),
            contentSize: NSSize(width: 240, height: 20),
            screenFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        )

        XCTAssertEqual(layout?.origin.x, 421)
    }

    func testInlinePreviewDoesNotFlipLeftWhenRightEdgeHasNoUsefulSpace() {
        let layout = InlinePreviewGeometry.layout(
            context: textContext(
                selectedRange: NSRange(location: 12, length: 0),
                caretRect: CGRect(x: 990, y: 500, width: 2, height: 20),
                focusedElementRect: CGRect(x: 900, y: 450, width: 100, height: 100)
            ),
            contentSize: NSSize(width: 120, height: 18),
            screenFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        )

        XCTAssertNil(layout)
    }

    func testNonCollapsedSelectionCannotUseInlineVisualPreview() {
        let layout = InlinePreviewGeometry.layout(
            context: textContext(
                selectedRange: NSRange(location: 12, length: 3),
                caretRect: CGRect(x: 100, y: 500, width: 2, height: 20),
                focusedElementRect: CGRect(x: 0, y: 450, width: 500, height: 100)
            ),
            contentSize: NSSize(width: 120, height: 18),
            screenFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        )

        XCTAssertNil(layout)
    }

    func testPreviousCharacterRectImprovesLineReference() {
        let context = textContext(
            selectedRange: NSRange(location: 12, length: 0),
            caretRect: CGRect(x: 100, y: 200, width: 2, height: 8),
            focusedElementRect: CGRect(x: 0, y: 150, width: 500, height: 100),
            previousGlyphRect: CGRect(x: 82, y: 190, width: 16, height: 24)
        )
        let layout = InlinePreviewGeometry.layout(
            context: context,
            contentSize: NSSize(width: 120, height: 20),
            screenFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        )

        XCTAssertEqual(InlinePreviewGeometry.referenceHeight(for: context), 24)
        XCTAssertEqual(layout?.origin.y, 786)
    }

    func testFocusedElementFallbackEstimatesInlinePositionInsideTextBox() {
        let focusedRect = CGRect(x: 120, y: 500, width: 520, height: 48)
        let layout = InlinePreviewGeometry.layout(
            context: textContext(
                textBeforeCursor: "Vamos tentar",
                selectedRange: NSRange(location: 13, length: 0),
                caretRect: nil,
                focusedElementRect: focusedRect
            ),
            contentSize: NSSize(width: 160, height: 18),
            screenFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        )

        let convertedFocus = OverlayGeometry.appKitRect(
            accessibilityRect: focusedRect,
            screenFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        )
        XCTAssertEqual(layout?.source, .textBoxEstimate)
        XCTAssertGreaterThan(layout?.origin.x ?? 0, convertedFocus.minX + 8)
        XCTAssertLessThan(layout?.origin.x ?? CGFloat.greatestFiniteMagnitude, convertedFocus.maxX)
        XCTAssertTrue(convertedFocus.insetBy(dx: -1, dy: -1).contains(CGPoint(x: layout?.origin.x ?? 0, y: layout?.origin.y ?? 0)))
    }

    func testWebLikeFineCaretWithoutGlyphUsesExactCaret() {
        let focusedRect = CGRect(x: 100, y: 700, width: 520, height: 72)
        let layout = InlinePreviewGeometry.layout(
            context: textContext(
                app: AppIdentity(bundleID: "com.openai.codex", displayName: "Codex", processID: 42),
                textBeforeCursor: "Vamos tentar ver se",
                selectedRange: NSRange(location: 19, length: 0),
                caretRect: CGRect(x: 390, y: 735, width: 2, height: 20),
                focusedElementRect: focusedRect,
                previousGlyphRect: nil
            ),
            contentSize: NSSize(width: 180, height: 18),
            screenFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        )

        XCTAssertEqual(layout?.source, .exactAX)
        XCTAssertEqual(layout?.origin.x, 393)
        XCTAssertEqual(layout?.origin.y, 245)
    }

    func testWebLikeSuspiciousCaretWithoutGlyphUsesTextBoxEstimate() {
        let focusedRect = CGRect(x: 100, y: 700, width: 520, height: 72)
        let layout = InlinePreviewGeometry.layout(
            context: textContext(
                app: AppIdentity(bundleID: "com.openai.codex", displayName: "Codex", processID: 42),
                textBeforeCursor: "Vamos tentar ver se",
                selectedRange: NSRange(location: 19, length: 0),
                caretRect: CGRect(x: 0, y: 1008, width: 0, height: 0),
                focusedElementRect: focusedRect,
                previousGlyphRect: nil
            ),
            contentSize: NSSize(width: 180, height: 18),
            screenFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        )

        let convertedFocus = OverlayGeometry.appKitRect(
            accessibilityRect: focusedRect,
            screenFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        )
        XCTAssertEqual(layout?.source, .textBoxEstimate)
        XCTAssertGreaterThan(layout?.origin.x ?? 0, convertedFocus.minX)
        XCTAssertLessThan(layout?.origin.x ?? CGFloat.greatestFiniteMagnitude, 300)
        XCTAssertGreaterThan(layout?.origin.y ?? 0, convertedFocus.minY)
        XCTAssertLessThan((layout?.origin.y ?? 0) + (layout?.size.height ?? 0), convertedFocus.maxY)
    }

    func testWebLikeLongTextEstimateUsesLastWrappedLineInsteadOfRightEdgeClamp() {
        let focusedRect = CGRect(x: 278, y: 829, width: 712, height: 88)
        let text = """
        Explique rapidamente o problema principal que estamos investigando agora e depois conclua com uma frase curta
        """
        let layout = InlinePreviewGeometry.layout(
            context: textContext(
                app: AppIdentity(bundleID: "com.openai.codex", displayName: "Codex", processID: 42),
                textBeforeCursor: text,
                selectedRange: NSRange(location: (text as NSString).length, length: 0),
                caretRect: CGRect(x: 0, y: 1008, width: 0, height: 0),
                focusedElementRect: focusedRect,
                previousGlyphRect: nil
            ),
            contentSize: NSSize(width: 180, height: 18),
            screenFrame: CGRect(x: 0, y: 0, width: 1_200, height: 1_000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_200, height: 1_000)
        )

        let convertedFocus = OverlayGeometry.appKitRect(
            accessibilityRect: focusedRect,
            screenFrame: CGRect(x: 0, y: 0, width: 1_200, height: 1_000)
        )
        XCTAssertEqual(layout?.source, .textBoxEstimate)
        XCTAssertLessThan(layout?.origin.x ?? CGFloat.greatestFiniteMagnitude, convertedFocus.maxX - 120)
        XCTAssertGreaterThan(layout?.origin.y ?? 0, convertedFocus.minY)
    }

    func testZeroOriginFocusedElementFallbackIsRejected() {
        let layout = InlinePreviewGeometry.layout(
            context: textContext(
                selectedRange: NSRange(location: 12, length: 0),
                caretRect: nil,
                focusedElementRect: CGRect(x: 0, y: 0, width: 500, height: 120)
            ),
            contentSize: NSSize(width: 120, height: 18),
            screenFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        )

        XCTAssertNil(layout)
    }

    func testZeroOriginMetricRectIsRejected() {
        let layout = InlinePreviewGeometry.layout(
            context: textContext(
                selectedRange: NSRange(location: 12, length: 0),
                caretRect: CGRect(x: 0, y: 0, width: 2, height: 20),
                focusedElementRect: CGRect(x: 0, y: 0, width: 500, height: 100),
                previousGlyphRect: nil
            ),
            contentSize: NSSize(width: 120, height: 18),
            screenFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        )

        XCTAssertNil(layout)
    }

    func testAccessibilityRectConvertsFromTopLeftToAppKitCoordinates() {
        let rect = OverlayGeometry.appKitRect(
            accessibilityRect: CGRect(x: 10, y: 20, width: 30, height: 40),
            screenFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        )

        XCTAssertEqual(rect, CGRect(x: 10, y: 940, width: 30, height: 40))
    }

    private func textContext(
        app: AppIdentity = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
        textBeforeCursor: String = "Hello world",
        selectedRange: NSRange?,
        caretRect: CGRect?,
        focusedElementRect: CGRect? = nil,
        previousGlyphRect: CGRect? = nil,
        nextGlyphRect: CGRect? = nil,
        lineReferenceRect: CGRect? = nil
    ) -> TextContext {
        TextContext(
            app: app,
            focusedElementID: "field",
            textBeforeCursor: textBeforeCursor,
            selectedRange: selectedRange,
            caretRect: caretRect,
            focusedElementRect: focusedElementRect,
            previousGlyphRect: previousGlyphRect,
            nextGlyphRect: nextGlyphRect,
            lineReferenceRect: lineReferenceRect
        )
    }
}
