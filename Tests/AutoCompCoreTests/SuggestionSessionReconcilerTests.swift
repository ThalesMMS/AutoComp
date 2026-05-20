import AutoCompCore
import XCTest

final class SuggestionSessionReconcilerTests: XCTestCase {
    func testFieldChangedReturnsTargetChanged() {
        let base = makeContext(focusedElementID: "field-a", textBeforeCursor: "Please ")
        let observed = makeContext(focusedElementID: "field-b", textBeforeCursor: "Please continue")
        let session = makeSession(base: base)

        let result = SuggestionSessionReconciler().reconcile(
            context: observed,
            session: session
        )

        XCTAssertEqual(result, .targetChanged)
    }

    func testSelectionAppearedReturnsDiverged() {
        let base = makeContext(textBeforeCursor: "Please ")
        let observed = makeContext(
            textBeforeCursor: "Please continue",
            selectedRange: NSRange(location: 6, length: 4)
        )
        let session = makeSession(base: base)

        let result = SuggestionSessionReconciler().reconcile(
            context: observed,
            session: session
        )

        XCTAssertEqual(result, .diverged)
    }

    func testDelayedEchoWithinGraceReturnsPendingEcho() {
        let acceptedAt = Date()
        let base = makeContext(textBeforeCursor: "Please ")
        let observed = makeContext(textBeforeCursor: "Please cont")
        let session = makeSession(base: base, lastAcceptedAt: acceptedAt)

        let result = SuggestionSessionReconciler().reconcile(
            context: observed,
            session: session,
            now: acceptedAt.addingTimeInterval(1)
        )

        XCTAssertEqual(result, .pendingEcho)
    }

    func testDelayedEchoAfterGraceReturnsDiverged() {
        let acceptedAt = Date()
        let base = makeContext(textBeforeCursor: "Please ")
        let observed = makeContext(textBeforeCursor: "Please cont")
        let session = makeSession(base: base, lastAcceptedAt: acceptedAt)

        let result = SuggestionSessionReconciler(acceptanceEchoGraceInterval: 1).reconcile(
            context: observed,
            session: session,
            now: acceptedAt.addingTimeInterval(2)
        )

        XCTAssertEqual(result, .diverged)
    }

    func testWhitespaceNormalizedEchoReturnsSettled() {
        let base = makeContext(textBeforeCursor: "Docs ")
        let observed = makeContext(textBeforeCursor: "Docs\u{00A0}continue")
        let session = makeSession(base: base, acceptedText: "continue")

        let result = SuggestionSessionReconciler().reconcile(
            context: observed,
            session: session
        )

        XCTAssertEqual(result, .settled)
    }

    func testTypedThroughAdvancesByOneCharacter() {
        let base = makeContext(textBeforeCursor: "Please ")
        let observed = makeContext(textBeforeCursor: "Please cont")
        let session = makeSession(
            base: base,
            acceptedText: "con",
            remainingText: "tinue please"
        )

        let result = SuggestionSessionReconciler().reconcile(
            context: observed,
            session: session
        )

        guard case .typedThrough(let updatedSession, let typedText) = result else {
            return XCTFail("Expected typed-through")
        }
        XCTAssertEqual(typedText, "t")
        XCTAssertEqual(updatedSession.acceptedText, "cont")
        XCTAssertEqual(updatedSession.remainingText, "inue please")
        XCTAssertEqual(updatedSession.consumedCharacterCount, 4)
    }

    func testTypedThroughAdvancesByMultipleCharacters() {
        let base = makeContext(textBeforeCursor: "Please ")
        let observed = makeContext(textBeforeCursor: "Please continue")
        let session = makeSession(
            base: base,
            acceptedText: "cont",
            remainingText: "inue please"
        )

        let result = SuggestionSessionReconciler().reconcile(
            context: observed,
            session: session
        )

        guard case .typedThrough(let updatedSession, let typedText) = result else {
            return XCTFail("Expected typed-through")
        }
        XCTAssertEqual(typedText, "inue")
        XCTAssertEqual(updatedSession.acceptedText, "continue")
        XCTAssertEqual(updatedSession.remainingText, " please")
    }

    func testTypedThroughCanExhaustSession() {
        let base = makeContext(textBeforeCursor: "Please ")
        let observed = makeContext(textBeforeCursor: "Please continue")
        let session = makeSession(
            base: base,
            acceptedText: "cont",
            remainingText: "inue"
        )

        let result = SuggestionSessionReconciler().reconcile(
            context: observed,
            session: session
        )

        guard case .typedThrough(let updatedSession, let typedText) = result else {
            return XCTFail("Expected typed-through")
        }
        XCTAssertEqual(typedText, "inue")
        XCTAssertTrue(updatedSession.isExhausted)
    }

    func testDivergenceInRemainingTextDoesNotAdvanceTypedThrough() {
        let base = makeContext(textBeforeCursor: "Please ")
        let observed = makeContext(textBeforeCursor: "Please cone")
        let session = makeSession(
            base: base,
            acceptedText: "con",
            remainingText: "tinue please"
        )

        let result = SuggestionSessionReconciler().reconcile(
            context: observed,
            session: session
        )

        XCTAssertEqual(result, .diverged)
    }

    func testAcceptedExhaustedSessionReturnsExhausted() {
        let base = makeContext(textBeforeCursor: "Please ")
        let observed = makeContext(textBeforeCursor: "Please continue")
        let session = makeSession(
            base: base,
            fullText: "continue",
            acceptedText: "continue",
            remainingText: ""
        )

        let result = SuggestionSessionReconciler().reconcile(
            context: observed,
            session: session
        )

        XCTAssertEqual(result, .exhausted)
    }

    private func makeSession(
        base: TextContext,
        fullText: String = "continue please",
        acceptedText: String = "continue",
        remainingText: String = " please",
        lastAcceptedAt: Date = Date()
    ) -> ActiveSuggestionSession {
        ActiveSuggestionSession(
            baseContext: base,
            fullText: fullText,
            acceptedText: acceptedText,
            remainingText: remainingText,
            latencyMs: 25,
            lastAcceptedAt: lastAcceptedAt
        )
    }

    private func makeContext(
        focusedElementID: String = "field-a",
        textBeforeCursor: String,
        selectedRange: NSRange? = NSRange(location: 0, length: 0)
    ) -> TextContext {
        TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: focusedElementID,
            textBeforeCursor: textBeforeCursor,
            selectedRange: selectedRange
        )
    }
}
