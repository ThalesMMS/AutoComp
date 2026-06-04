import AutoCompCore
import CoreGraphics
import XCTest

final class InteractionTargetMatcherTests: XCTestCase {
    func testMatchesExactFocusedElementID() {
        let previous = textContext(focusedElementID: "field-a")
        let current = textContext(
            focusedElementID: "field-a",
            focusedElementRect: CGRect(x: 900, y: 900, width: 200, height: 40)
        )

        XCTAssertTrue(InteractionTargetMatcher.matches(current, as: previous))
    }

    func testMatchesStableFieldIdentityWhenFocusedElementIDDrifts() {
        let app = AppIdentity(bundleID: "com.test.editor", displayName: "Editor", processID: 123)
        let stableIdentity = StableFieldIdentity(
            app: app,
            domain: "example.com",
            role: "AXTextArea",
            focusedElementFrame: CGRect(x: 100, y: 100, width: 500, height: 40)
        )
        let previous = textContext(
            app: app,
            domain: "example.com",
            focusedElementID: "volatile-a",
            stableFieldIdentity: stableIdentity
        )
        let current = textContext(
            app: app,
            domain: "example.com",
            focusedElementID: "volatile-b",
            stableFieldIdentity: stableIdentity
        )

        XCTAssertTrue(InteractionTargetMatcher.matches(current, as: previous))
    }

    func testMatchesFocusIdentityCaretMetrics() {
        let previous = textContext(
            focusedElementID: "field-a",
            focusedElementRect: nil,
            caretRect: CGRect(x: 220, y: 120, width: 2, height: 18)
        )
        let current = textContext(
            focusedElementID: "field-b",
            focusedElementRect: nil,
            caretRect: CGRect(x: 223, y: 122, width: 2, height: 18)
        )

        XCTAssertTrue(InteractionTargetMatcher.matches(current, as: previous))
    }

    func testMatchesApproximateFocusedElementGeometry() {
        let previous = textContext(
            focusedElementID: "field-a",
            focusedElementRect: CGRect(x: 100, y: 100, width: 500, height: 40)
        )
        let current = textContext(
            focusedElementID: "field-b",
            focusedElementRect: CGRect(x: 106, y: 104, width: 496, height: 43)
        )

        XCTAssertTrue(InteractionTargetMatcher.matches(current, as: previous))
    }

    func testMatchesScreenOCRGeometryTolerance() {
        let previous = textContext(
            focusedElementID: "field-a",
            focusedElementRect: nil,
            caretRect: CGRect(x: 220, y: 120, width: 2, height: 18),
            caretGeometryQuality: .screenOCR,
            captureSources: [.accessibility, .screenOCR]
        )
        let current = textContext(
            focusedElementID: "field-b",
            focusedElementRect: nil,
            caretRect: CGRect(x: 235, y: 134, width: 2, height: 18),
            caretGeometryQuality: .screenOCR,
            captureSources: [.accessibility, .screenOCR]
        )

        XCTAssertTrue(InteractionTargetMatcher.matches(current, as: previous))
    }

    func testMatchesGoogleDocsVolatileLineMetricGeometry() {
        let app = AppIdentity(bundleID: "com.google.Chrome", displayName: "Chrome", processID: 456)
        let previous = textContext(
            app: app,
            domain: "docs.google.com/document/d/abc",
            focusedElementID: "docs-line-a",
            focusedElementRect: CGRect(x: 360, y: 430, width: 520, height: 34)
        )
        let current = textContext(
            app: app,
            domain: "docs.google.com/document/d/abc",
            focusedElementID: "docs-line-b",
            focusedElementRect: CGRect(x: 420, y: 476, width: 640, height: 38)
        )

        XCTAssertTrue(InteractionTargetMatcher.matches(current, as: previous))
    }

    func testRejectsTrueMismatch() {
        let previous = textContext(
            focusedElementID: "field-a",
            focusedElementRect: CGRect(x: 100, y: 100, width: 500, height: 40),
            caretRect: CGRect(x: 580, y: 112, width: 2, height: 18)
        )
        let current = textContext(
            focusedElementID: "field-b",
            focusedElementRect: CGRect(x: 100, y: 260, width: 500, height: 40),
            caretRect: CGRect(x: 580, y: 272, width: 2, height: 18)
        )

        XCTAssertFalse(InteractionTargetMatcher.matches(current, as: previous))
    }

    private func textContext(
        app: AppIdentity = AppIdentity(bundleID: "com.test.editor", displayName: "Editor", processID: 123),
        domain: String? = nil,
        focusedElementID: String = "field-a",
        stableFieldIdentity: StableFieldIdentity? = nil,
        focusedElementRect: CGRect? = CGRect(x: 100, y: 100, width: 500, height: 40),
        caretRect: CGRect? = nil,
        caretGeometryQuality: CaretGeometryQuality = .directCaret,
        captureSources: Set<TextCaptureSource> = [.accessibility]
    ) -> TextContext {
        TextContext(
            app: app,
            domain: domain,
            focusedElementID: focusedElementID,
            stableFieldIdentity: stableFieldIdentity,
            textBeforeCursor: "Hello ",
            textAfterCursor: nil,
            caretRect: caretRect,
            focusedElementRect: focusedElementRect,
            caretGeometryQuality: caretGeometryQuality,
            captureSources: captureSources
        )
    }
}
