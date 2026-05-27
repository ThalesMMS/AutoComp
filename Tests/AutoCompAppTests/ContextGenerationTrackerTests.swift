import AutoCompCore
import CoreGraphics
@testable import AutoCompApp
import XCTest

final class ContextGenerationTrackerTests: XCTestCase {
    func testProducesStrictGenerationSignature() {
        let tracker = ContextGenerationTracker()
        let context = textContext(
            focusedElementID: "field-a",
            textBeforeCursor: "Please ",
            selectedRange: NSRange(location: 7, length: 0),
            focusedElementRect: CGRect(x: 200, y: 100, width: 600, height: 40),
            caretRect: CGRect(x: 260, y: 110, width: 1, height: 18)
        )

        let signature: StrictGenerationSignature = tracker.signature(for: context)

        XCTAssertEqual(signature.app, context.app)
        XCTAssertEqual(signature.domain, context.domain)
        XCTAssertEqual(signature.focusedElementID, "field-a")
        XCTAssertEqual(signature.textBeforeCursor, "Please ")
        XCTAssertEqual(signature.selectedRangeLocation, 7)
        XCTAssertEqual(signature.selectedRangeLength, 0)
    }

    func testMatchesWhenElementIDChangesButGeometryTextAndSelectionStayStable() {
        let tracker = ContextGenerationTracker()
        let requestedContext = textContext(
            focusedElementID: "field-a",
            textBeforeCursor: "Please ",
            selectedRange: NSRange(location: 7, length: 0),
            focusedElementRect: CGRect(x: 200, y: 100, width: 600, height: 40),
            caretRect: CGRect(x: 260, y: 110, width: 1, height: 18)
        )
        let liveContext = textContext(
            focusedElementID: "field-b",
            textBeforeCursor: "Please ",
            selectedRange: NSRange(location: 7, length: 0),
            focusedElementRect: CGRect(x: 201, y: 101, width: 600, height: 40),
            caretRect: CGRect(x: 261, y: 110, width: 1, height: 18)
        )

        XCTAssertTrue(tracker.matches(liveContext, signature: tracker.signature(for: requestedContext)))
    }

    func testRejectsDifferentFieldWhenElementIDAndGeometryChange() {
        let tracker = ContextGenerationTracker()
        let requestedContext = textContext(
            focusedElementID: "field-a",
            textBeforeCursor: "Please ",
            selectedRange: NSRange(location: 7, length: 0),
            focusedElementRect: CGRect(x: 200, y: 100, width: 600, height: 40),
            caretRect: CGRect(x: 260, y: 110, width: 1, height: 18)
        )
        let liveContext = textContext(
            focusedElementID: "field-b",
            textBeforeCursor: "Please ",
            selectedRange: NSRange(location: 7, length: 0),
            focusedElementRect: CGRect(x: 200, y: 260, width: 600, height: 40),
            caretRect: CGRect(x: 260, y: 270, width: 1, height: 18)
        )

        XCTAssertFalse(tracker.matches(liveContext, signature: tracker.signature(for: requestedContext)))
    }

    func testScreenOCRGeometryJitterKeepsGenerationFresh() {
        let tracker = ContextGenerationTracker()
        let requestedContext = textContext(
            app: AppIdentity(bundleID: "com.apple.Safari", displayName: "Safari", processID: 1),
            domain: "docs.google.com",
            focusedElementID: "docs-field-a",
            textBeforeCursor: "Testando uma ferramenta de ",
            selectedRange: NSRange(location: 27, length: 0),
            focusedElementRect: CGRect(x: 1033.4, y: 510.8, width: 512.9, height: 40),
            caretRect: CGRect(x: 1225.3, y: 518.8, width: 1, height: 14.9),
            caretGeometryQuality: .screenOCR,
            captureSources: [.accessibility, .screenOCR]
        )
        let liveContext = textContext(
            app: AppIdentity(bundleID: "com.apple.Safari", displayName: "Safari", processID: 1),
            domain: "docs.google.com",
            focusedElementID: "docs-field-b",
            textBeforeCursor: "Testando uma ferramenta de ",
            selectedRange: NSRange(location: 27, length: 0),
            focusedElementRect: CGRect(x: 1033.4, y: 510.8, width: 503.0, height: 40),
            caretRect: CGRect(x: 1215.4, y: 518.8, width: 1, height: 14.9),
            caretGeometryQuality: .screenOCR,
            captureSources: [.accessibility, .screenOCR]
        )

        XCTAssertTrue(tracker.matches(liveContext, signature: tracker.signature(for: requestedContext)))
    }

    func testWebTrailingWhitespaceNormalizationKeepsGenerationFresh() {
        let tracker = ContextGenerationTracker()
        let requestedContext = textContext(
            app: AppIdentity(bundleID: "com.google.Chrome", displayName: "Google Chrome", processID: 1),
            domain: "docs.google.com",
            focusedElementID: "docs-field-a",
            textBeforeCursor: "Docs ",
            selectedRange: NSRange(location: 5, length: 0),
            focusedElementRect: CGRect(x: 450, y: 381, width: 626, height: 1),
            caretRect: CGRect(x: 450, y: 381, width: 0, height: 17)
        )
        let liveContext = textContext(
            app: AppIdentity(bundleID: "com.google.Chrome", displayName: "Google Chrome", processID: 1),
            domain: "docs.google.com",
            focusedElementID: "docs-field-b",
            textBeforeCursor: "Docs",
            selectedRange: NSRange(location: 4, length: 0),
            focusedElementRect: CGRect(x: 450, y: 381, width: 626, height: 1),
            caretRect: CGRect(x: 450, y: 381, width: 0, height: 17)
        )

        XCTAssertTrue(tracker.matches(liveContext, signature: tracker.signature(for: requestedContext)))
    }

    func testGoogleDocsScreenOCRFocusIdentityChurnKeepsGenerationFresh() {
        let tracker = ContextGenerationTracker()
        let requestedContext = textContext(
            app: AppIdentity(bundleID: "com.google.Chrome", displayName: "Google Chrome", processID: 1),
            domain: "docs.google.com",
            focusedElementID: "77563-0x0000000c06d4c210",
            textBeforeCursor: "sexta rodada setima rodada ",
            selectedRange: NSRange(location: 27, length: 0),
            focusedElementRect: CGRect(x: 430, y: 264, width: 626, height: 1),
            caretRect: CGRect(x: 505, y: 278, width: 0, height: 17),
            caretGeometryQuality: .screenOCR,
            captureSources: [.accessibility, .screenOCR]
        )
        let liveContext = textContext(
            app: AppIdentity(bundleID: "com.google.Chrome", displayName: "Google Chrome", processID: 1),
            domain: "docs.google.com",
            focusedElementID: "77563-0x0000000c06d4e100",
            textBeforeCursor: "sexta rodada setima rodada ",
            selectedRange: NSRange(location: 27, length: 0),
            focusedElementRect: CGRect(x: 800, y: 640, width: 400, height: 12),
            caretRect: CGRect(x: 900, y: 650, width: 0, height: 17),
            caretGeometryQuality: .screenOCR,
            captureSources: [.accessibility, .screenOCR]
        )

        XCTAssertTrue(tracker.matches(liveContext, signature: tracker.signature(for: requestedContext)))
    }

    func testNonGoogleDocsFocusIdentityChurnStillRejectsDifferentTarget() {
        let tracker = ContextGenerationTracker()
        let requestedContext = textContext(
            app: AppIdentity(bundleID: "com.google.Chrome", displayName: "Google Chrome", processID: 1),
            domain: "example.com",
            focusedElementID: "field-a",
            textBeforeCursor: "Example ",
            selectedRange: NSRange(location: 8, length: 0),
            focusedElementRect: CGRect(x: 100, y: 100, width: 300, height: 30),
            caretRect: CGRect(x: 180, y: 106, width: 1, height: 18),
            caretGeometryQuality: .screenOCR,
            captureSources: [.accessibility, .screenOCR]
        )
        let liveContext = textContext(
            app: AppIdentity(bundleID: "com.google.Chrome", displayName: "Google Chrome", processID: 1),
            domain: "example.com",
            focusedElementID: "field-b",
            textBeforeCursor: "Example ",
            selectedRange: NSRange(location: 8, length: 0),
            focusedElementRect: CGRect(x: 100, y: 300, width: 300, height: 30),
            caretRect: CGRect(x: 180, y: 306, width: 1, height: 18),
            caretGeometryQuality: .screenOCR,
            captureSources: [.accessibility, .screenOCR]
        )

        XCTAssertFalse(tracker.matches(liveContext, signature: tracker.signature(for: requestedContext)))
    }

    func testRejectsAppDomainTextAndSelectionChanges() {
        let tracker = ContextGenerationTracker()
        let requestedContext = textContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            domain: nil,
            focusedElementID: "field-a",
            textBeforeCursor: "Please ",
            selectedRange: NSRange(location: 7, length: 0),
            focusedElementRect: CGRect(x: 200, y: 100, width: 600, height: 40),
            caretRect: CGRect(x: 260, y: 110, width: 1, height: 18)
        )
        let signature = tracker.signature(for: requestedContext)

        XCTAssertFalse(
            tracker.matches(
                textContext(
                    app: AppIdentity(bundleID: "com.apple.Notes", displayName: "Notes", processID: 2),
                    focusedElementID: "field-a",
                    textBeforeCursor: "Please ",
                    selectedRange: NSRange(location: 7, length: 0),
                    focusedElementRect: requestedContext.focusedElementRect,
                    caretRect: requestedContext.caretRect
                ),
                signature: signature
            )
        )
        XCTAssertFalse(
            tracker.matches(
                textContext(
                    domain: "docs.google.com",
                    focusedElementID: "field-a",
                    textBeforeCursor: "Please ",
                    selectedRange: NSRange(location: 7, length: 0),
                    focusedElementRect: requestedContext.focusedElementRect,
                    caretRect: requestedContext.caretRect
                ),
                signature: signature
            )
        )
        XCTAssertFalse(
            tracker.matches(
                textContext(
                    focusedElementID: "field-a",
                    textBeforeCursor: "Please changed",
                    selectedRange: NSRange(location: 7, length: 0),
                    focusedElementRect: requestedContext.focusedElementRect,
                    caretRect: requestedContext.caretRect
                ),
                signature: signature
            )
        )
        XCTAssertFalse(
            tracker.matches(
                textContext(
                    focusedElementID: "field-a",
                    textBeforeCursor: "Please ",
                    selectedRange: NSRange(location: 0, length: 7),
                    focusedElementRect: requestedContext.focusedElementRect,
                    caretRect: requestedContext.caretRect
                ),
                signature: signature
            )
        )
    }

    private func textContext(
        app: AppIdentity = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
        domain: String? = nil,
        focusedElementID: String,
        textBeforeCursor: String,
        selectedRange: NSRange?,
        focusedElementRect: CGRect?,
        caretRect: CGRect?,
        caretGeometryQuality: CaretGeometryQuality = .unavailable,
        captureSources: Set<TextCaptureSource> = [.accessibility]
    ) -> TextContext {
        TextContext(
            app: app,
            domain: domain,
            focusedElementID: focusedElementID,
            textBeforeCursor: textBeforeCursor,
            selectedRange: selectedRange,
            caretRect: caretRect,
            focusedElementRect: focusedElementRect,
            caretGeometryQuality: caretGeometryQuality,
            captureSources: captureSources
        )
    }
}
