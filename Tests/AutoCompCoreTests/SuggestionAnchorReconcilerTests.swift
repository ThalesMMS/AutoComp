import AutoCompCore
import CoreGraphics
import XCTest

final class SuggestionAnchorReconcilerTests: XCTestCase {
    func testTypedThroughReturnsRemainingText() {
        let base = makeContext(textBeforeCursor: "")
        let anchor = SuggestionAnchor(
            context: base,
            fullText: "hello world",
            acceptedText: "",
            remainingText: "hello world"
        )
        let live = makeContext(textBeforeCursor: "hello ")

        XCTAssertEqual(
            SuggestionAnchorReconciler().reconcile(context: live, anchor: anchor),
            .remaining("world")
        )
    }

    func testFullyConsumedSuggestionReturnsExhausted() {
        let base = makeContext(textBeforeCursor: "")
        let anchor = SuggestionAnchor(
            context: base,
            fullText: "hello world",
            acceptedText: "hello world",
            remainingText: ""
        )
        let live = makeContext(textBeforeCursor: "hello world")

        XCTAssertEqual(
            SuggestionAnchorReconciler().reconcile(context: live, anchor: anchor),
            .exhausted
        )
    }

    func testDivergedWhenTypedTextDoesNotMatchRemainingSuggestion() {
        let base = makeContext(textBeforeCursor: "")
        let anchor = SuggestionAnchor(
            context: base,
            fullText: "hello world",
            acceptedText: "",
            remainingText: "hello world"
        )
        let live = makeContext(textBeforeCursor: "hullo")

        XCTAssertEqual(
            SuggestionAnchorReconciler().reconcile(context: live, anchor: anchor),
            .diverged(reason: .typedTextMismatch)
        )
    }

    func testBackspaceIntoAcceptedTextDiverges() {
        let base = makeContext(textBeforeCursor: "")
        let anchor = SuggestionAnchor(
            context: base,
            fullText: "hello world",
            acceptedText: "hello ",
            remainingText: "world"
        )
        let live = makeContext(textBeforeCursor: "hello")

        XCTAssertEqual(
            SuggestionAnchorReconciler().reconcile(context: live, anchor: anchor),
            .diverged(reason: .acceptedTextDeleted)
        )
    }

    func testSuffixChangeDiverges() {
        let base = makeContext(textBeforeCursor: "hello", textAfterCursor: " world")
        let anchor = SuggestionAnchor(
            context: base,
            fullText: " brave",
            acceptedText: "",
            remainingText: " brave"
        )
        let live = makeContext(textBeforeCursor: "hello", textAfterCursor: " there")

        XCTAssertEqual(
            SuggestionAnchorReconciler().reconcile(context: live, anchor: anchor),
            .diverged(reason: .suffixChanged)
        )
    }

    func testDomainChangeDiverges() {
        let base = makeContext(textBeforeCursor: "hello", domain: "example.com")
        let anchor = SuggestionAnchor(
            context: base,
            fullText: " world",
            acceptedText: "",
            remainingText: " world"
        )
        let live = makeContext(textBeforeCursor: "hello", domain: "other.example")

        XCTAssertEqual(
            SuggestionAnchorReconciler().reconcile(context: live, anchor: anchor),
            .diverged(reason: .domainChanged)
        )
    }

    func testAppChangeDiverges() {
        let base = makeContext(textBeforeCursor: "hello")
        let anchor = SuggestionAnchor(
            context: base,
            fullText: " world",
            acceptedText: "",
            remainingText: " world"
        )
        let live = makeContext(
            textBeforeCursor: "hello",
            app: AppIdentity(bundleID: "com.apple.Notes", displayName: "Notes", processID: 2)
        )

        XCTAssertEqual(
            SuggestionAnchorReconciler().reconcile(context: live, anchor: anchor),
            .diverged(reason: .appChanged)
        )
    }

    func testSameOriginalSelectionCanStillReturnRemainingText() {
        let selectedRange = NSRange(location: 6, length: 5)
        let base = makeContext(
            textBeforeCursor: "hello ",
            selectedText: "world",
            selectedRange: selectedRange
        )
        let anchor = SuggestionAnchor(
            context: base,
            fullText: "there",
            acceptedText: "",
            remainingText: "there"
        )
        let live = makeContext(
            textBeforeCursor: "hello ",
            selectedText: "world",
            selectedRange: selectedRange
        )

        XCTAssertEqual(
            SuggestionAnchorReconciler().reconcile(context: live, anchor: anchor),
            .remaining("there")
        )
    }

    func testStableFieldIdentityChangeDiverges() {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let base = makeContext(
            textBeforeCursor: "hello",
            app: app,
            stableFieldIdentity: StableFieldIdentity(
                app: app,
                focusedElementFrame: CGRect(x: 100, y: 100, width: 200, height: 30),
                focusChangeSequence: 1
            )
        )
        let anchor = SuggestionAnchor(
            context: base,
            fullText: " world",
            acceptedText: "",
            remainingText: " world"
        )
        let live = makeContext(
            textBeforeCursor: "hello",
            app: app,
            stableFieldIdentity: StableFieldIdentity(
                app: app,
                focusedElementFrame: CGRect(x: 100, y: 100, width: 200, height: 30),
                focusChangeSequence: 2
            )
        )

        XCTAssertEqual(
            SuggestionAnchorReconciler().reconcile(context: live, anchor: anchor),
            .diverged(reason: .stableFieldChanged)
        )
    }

    func testChangedSelectionDiverges() {
        let base = makeContext(textBeforeCursor: "hello")
        let anchor = SuggestionAnchor(
            context: base,
            fullText: " world",
            acceptedText: "",
            remainingText: " world"
        )
        let live = makeContext(
            textBeforeCursor: "hello",
            selectedText: "ell",
            selectedRange: NSRange(location: 1, length: 3)
        )

        XCTAssertEqual(
            SuggestionAnchorReconciler().reconcile(context: live, anchor: anchor),
            .diverged(reason: .selectionChanged)
        )
    }

}
