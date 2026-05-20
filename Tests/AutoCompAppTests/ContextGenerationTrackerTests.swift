import AutoCompCore
import CoreGraphics
@testable import AutoCompApp
import XCTest

final class ContextGenerationTrackerTests: XCTestCase {
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
        caretRect: CGRect?
    ) -> TextContext {
        TextContext(
            app: app,
            domain: domain,
            focusedElementID: focusedElementID,
            textBeforeCursor: textBeforeCursor,
            selectedRange: selectedRange,
            caretRect: caretRect,
            focusedElementRect: focusedElementRect
        )
    }
}
