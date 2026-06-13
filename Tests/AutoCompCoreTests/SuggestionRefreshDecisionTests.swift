import AutoCompCore
import CoreGraphics
import XCTest

final class SuggestionRefreshDecisionTests: XCTestCase {
    func testEmptyContextRequestsEmptyEligibilityBranch() {
        let input = input(context: textContext(textBeforeCursor: " \n"))

        XCTAssertEqual(SuggestionRefreshDecisionEngine.decide(input), .evaluateEmptyContextEligibility)
    }

    func testDismissalStillAppliesWhenFocusedTextMatches() {
        let context = textContext(textBeforeCursor: "Hello ")
        let dismissedContext = textContext(textBeforeCursor: "Hello ")
        let input = input(context: context, dismissedContext: dismissedContext)

        XCTAssertEqual(SuggestionRefreshDecisionEngine.decide(input), .keepDismissed)
    }

    func testExpiredDismissalClearsBeforeContinuing() {
        let context = textContext(textBeforeCursor: "Hello world ")
        let dismissedContext = textContext(textBeforeCursor: "Hello ")
        let input = input(context: context, dismissedContext: dismissedContext)

        XCTAssertEqual(SuggestionRefreshDecisionEngine.decide(input), .clearDismissalAndContinue)
    }

    func testLeakedShortcutRepairTakesPrecedenceOverKeeps() {
        let previous = textContext(textBeforeCursor: "Hello ")
        let context = textContext(textBeforeCursor: "Hello \t")
        let suggestion = Suggestion(baseContextID: previous.id, visibleText: "world", latencyMs: 10)
        let input = input(
            context: context,
            previousContext: previous,
            currentSuggestion: suggestion,
            leakedShortcutRepairNeeded: true
        )

        XCTAssertEqual(SuggestionRefreshDecisionEngine.decide(input), .repairLeakedShortcut)
    }

    func testCompletedAcceptAllRepairTakesPrecedenceOverKeeps() {
        let previous = textContext(textBeforeCursor: "Hello ")
        let context = textContext(textBeforeCursor: "Hello ")
        let suggestion = Suggestion(baseContextID: previous.id, visibleText: "world", latencyMs: 10)
        let input = input(
            context: context,
            previousContext: previous,
            currentSuggestion: suggestion,
            completedAcceptAllRepairNeeded: true
        )

        XCTAssertEqual(SuggestionRefreshDecisionEngine.decide(input), .repairCompletedAcceptAll)
    }

    func testWebWhitespaceDriftKeepsSuggestionUsingPreviousPresentationText() {
        let previous = textContext(
            app: webApp,
            focusedElementID: "web-field",
            textBeforeCursor: "Hello "
        )
        let context = textContext(
            app: webApp,
            focusedElementID: "web-field",
            textBeforeCursor: "Hello"
        )
        let suggestion = Suggestion(baseContextID: previous.id, visibleText: "world", latencyMs: 10)
        let input = input(context: context, previousContext: previous, currentSuggestion: suggestion)

        XCTAssertEqual(
            SuggestionRefreshDecisionEngine.decide(input),
            .keepSuggestion(reason: .webWhitespaceNormalization, presentationContext: context.replacingTextBeforeCursor("Hello "))
        )
    }

    func testAcceptedSessionCanHandleBeforeSameFocusedTextKeep() {
        let context = textContext(textBeforeCursor: "Hello ")
        let previous = textContext(textBeforeCursor: "Hello ")
        let suggestion = Suggestion(baseContextID: previous.id, visibleText: "world", latencyMs: 10)
        let input = input(
            context: context,
            previousContext: previous,
            currentSuggestion: suggestion,
            acceptedSessionCanHandle: true
        )

        XCTAssertEqual(SuggestionRefreshDecisionEngine.decide(input), .handleAcceptedSession)
    }

    func testSameFocusedTextKeepsSuggestion() {
        let context = textContext(textBeforeCursor: "Hello ")
        let previous = textContext(textBeforeCursor: "Hello ")
        let suggestion = Suggestion(baseContextID: previous.id, visibleText: "world", latencyMs: 10)
        let input = input(context: context, previousContext: previous, currentSuggestion: suggestion)

        XCTAssertEqual(
            SuggestionRefreshDecisionEngine.decide(input),
            .keepSuggestion(reason: .sameFocusedText, presentationContext: context)
        )
    }

    func testAcceptedPrefixConsistencyKeepsSuggestion() {
        let context = textContext(textBeforeCursor: "Hello world ")
        let previous = textContext(textBeforeCursor: "Hello ")
        let suggestion = Suggestion(
            baseContextID: previous.id,
            visibleText: "again",
            remainingText: "again",
            acceptedPrefix: "world ",
            latencyMs: 10
        )
        let input = input(
            context: context,
            previousContext: previous,
            currentSuggestion: suggestion,
            acceptedPrefixConsistent: true
        )

        XCTAssertEqual(
            SuggestionRefreshDecisionEngine.decide(input),
            .keepSuggestion(reason: .acceptedPrefixConsistent, presentationContext: context)
        )
    }

    func testIneligibleDecisionIsReturnedAfterEligibilityEvaluation() {
        let decision = SuggestionEligibilityDecision(outcome: .ineligible(.awaitingSpaceTrigger), logs: [])
        let input = input(
            context: textContext(textBeforeCursor: "Hello"),
            eligibilityDecision: decision
        )

        XCTAssertEqual(SuggestionRefreshDecisionEngine.decide(input), .ineligible(decision))
    }

    func testEligibleDecisionRequestsCompletion() {
        let decision = SuggestionEligibilityDecision(outcome: .eligible, logs: [])
        let input = input(
            context: textContext(textBeforeCursor: "Hello "),
            eligibilityDecision: decision
        )

        XCTAssertEqual(SuggestionRefreshDecisionEngine.decide(input), .requestCompletion)
    }

    private func input(
        context: TextContext,
        previousContext: TextContext? = nil,
        currentSuggestion: Suggestion? = nil,
        dismissedContext: TextContext? = nil,
        acceptedPrefixConsistent: Bool = false,
        leakedShortcutRepairNeeded: Bool = false,
        completedAcceptAllRepairNeeded: Bool = false,
        acceptedSessionCanHandle: Bool = false,
        eligibilityDecision: SuggestionEligibilityDecision? = nil
    ) -> SuggestionRefreshDecisionInput {
        SuggestionRefreshDecisionInput(
            context: context,
            previousContext: previousContext,
            currentSuggestion: currentSuggestion,
            dismissedContext: dismissedContext,
            acceptedPrefixConsistent: acceptedPrefixConsistent,
            leakedShortcutRepairNeeded: leakedShortcutRepairNeeded,
            completedAcceptAllRepairNeeded: completedAcceptAllRepairNeeded,
            acceptedSessionCanHandle: acceptedSessionCanHandle,
            eligibilityDecision: eligibilityDecision
        )
    }

    private func textContext(
        app: AppIdentity = AppIdentity(bundleID: "com.test.editor", displayName: "Editor", processID: 123),
        focusedElementID: String = "field-a",
        textBeforeCursor: String
    ) -> TextContext {
        TextContext(
            app: app,
            focusedElementID: focusedElementID,
            textBeforeCursor: textBeforeCursor,
            textAfterCursor: nil,
            focusedElementRect: CGRect(x: 100, y: 100, width: 500, height: 40)
        )
    }

    private var webApp: AppIdentity {
        AppIdentity(bundleID: "com.apple.Safari", displayName: "Safari", processID: 456)
    }
}

private extension TextContext {
    func replacingTextBeforeCursor(_ textBeforeCursor: String) -> TextContext {
        self.copy(textBeforeCursor: textBeforeCursor)
    }
}
