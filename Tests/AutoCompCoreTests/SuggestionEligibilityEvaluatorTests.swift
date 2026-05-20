import AutoCompCore
import CoreGraphics
import XCTest

final class SuggestionEligibilityEvaluatorTests: XCTestCase {
    private let evaluator = SuggestionEligibilityEvaluator()
    private let now = Date(timeIntervalSinceReferenceDate: 1_000)

    func testCompatibilitySkipReturnsStatusAndLogData() {
        let context = textContext(textBeforeCursor: "Hello")
        let profile = AppCompatibilityProfile(
            bundleID: context.app.bundleID,
            displayName: context.app.displayName,
            status: .unsupported,
            defaultMode: .disabled,
            notes: "Unsupported app",
            enabledByDefault: false
        )
        let compatibilityDecision = CompatibilityDecision(
            profile: profile,
            mode: .disabled,
            enabled: false
        )

        let decision = evaluator.evaluate(
            context: context,
            previousContext: nil,
            compatibilityDecision: compatibilityDecision,
            lastSuggestionTriggerKeyAt: .distantPast,
            now: now
        )

        XCTAssertEqual(decision.outcome, .ineligible(.compatibility))
        XCTAssertEqual(decision.statusMessage, "Unsupported app")
        XCTAssertEqual(decision.logs.map(\.kind), [.skip(.compatibility)])
        XCTAssertEqual(decision.logs.first?.compatibilityEnabled, false)
        XCTAssertEqual(decision.logs.first?.displayMode, .disabled)
        XCTAssertEqual(decision.logs.first?.compatibilityStatus, .unsupported)
    }

    func testEmptyContextSkipsBeforeCompatibility() {
        let context = textContext(textBeforeCursor: " \n")
        let profile = AppCompatibilityProfile(
            bundleID: context.app.bundleID,
            displayName: context.app.displayName,
            status: .unsupported,
            defaultMode: .disabled,
            enabledByDefault: false
        )
        let compatibilityDecision = CompatibilityDecision(
            profile: profile,
            mode: .disabled,
            enabled: false
        )

        let decision = evaluator.evaluate(
            context: context,
            previousContext: nil,
            compatibilityDecision: compatibilityDecision,
            lastSuggestionTriggerKeyAt: .distantPast,
            now: now
        )

        XCTAssertEqual(decision.outcome, .ineligible(.emptyContext))
        XCTAssertEqual(decision.statusMessage, "Waiting for text")
        XCTAssertEqual(decision.logs.map(\.kind), [.skip(.emptyContext)])
    }

    func testSentenceCompleteSkipsBeforeWhitespaceTrigger() {
        let context = textContext(textBeforeCursor: "This is done.")

        let decision = evaluator.evaluate(
            context: context,
            previousContext: nil,
            compatibilityDecision: supportedCompatibilityDecision(for: context),
            lastSuggestionTriggerKeyAt: .distantPast,
            now: now
        )

        XCTAssertEqual(decision.outcome, .ineligible(.sentenceComplete))
        XCTAssertEqual(decision.statusMessage, "Sentence complete")
        XCTAssertEqual(decision.logs.map(\.kind), [.skip(.sentenceComplete)])
    }

    func testUnchangedContextSkipsWithoutChangingStatus() {
        let previousContext = textContext(textBeforeCursor: "Keep waiting")
        let currentContext = textContext(
            focusedElementID: "different-field",
            textBeforeCursor: previousContext.textBeforeCursor
        )

        let decision = evaluator.evaluate(
            context: currentContext,
            previousContext: previousContext,
            compatibilityDecision: supportedCompatibilityDecision(for: currentContext),
            lastSuggestionTriggerKeyAt: .distantPast,
            now: now
        )

        XCTAssertEqual(decision.outcome, .ineligible(.unchangedContext))
        XCTAssertNil(decision.statusMessage)
        XCTAssertEqual(decision.logs.map(\.kind), [.skip(.unchangedContext)])
    }

    func testChangedTextWithoutTrailingWhitespaceWaitsForSpace() {
        let previousContext = textContext(textBeforeCursor: "Hello")
        let currentContext = textContext(textBeforeCursor: "Hello world")

        let decision = evaluator.evaluate(
            context: currentContext,
            previousContext: previousContext,
            compatibilityDecision: supportedCompatibilityDecision(for: currentContext),
            lastSuggestionTriggerKeyAt: .distantPast,
            now: now
        )

        XCTAssertEqual(decision.outcome, .ineligible(.awaitingSpaceTrigger))
        XCTAssertEqual(decision.statusMessage, "Waiting for space")
        XCTAssertEqual(decision.logs.map(\.kind), [.eligible, .skip(.awaitingSpaceTrigger)])
    }

    func testObservedTrailingWhitespaceChangeIsEligible() {
        let previousContext = textContext(textBeforeCursor: "Hello")
        let currentContext = textContext(textBeforeCursor: "Hello ")

        let decision = evaluator.evaluate(
            context: currentContext,
            previousContext: previousContext,
            compatibilityDecision: supportedCompatibilityDecision(for: currentContext),
            lastSuggestionTriggerKeyAt: .distantPast,
            now: now
        )

        XCTAssertEqual(decision.outcome, .eligible)
        XCTAssertNil(decision.statusMessage)
        XCTAssertEqual(decision.logs.map(\.kind), [.eligible])
    }

    func testInitialTrailingWhitespaceWaitsWithoutRecentSpaceKey() {
        let context = textContext(textBeforeCursor: "Already typed ")

        let decision = evaluator.evaluate(
            context: context,
            previousContext: nil,
            compatibilityDecision: supportedCompatibilityDecision(for: context),
            lastSuggestionTriggerKeyAt: .distantPast,
            now: now
        )

        XCTAssertEqual(decision.outcome, .ineligible(.awaitingSpaceTrigger))
        XCTAssertEqual(decision.statusMessage, "Waiting for space")
        XCTAssertEqual(decision.logs.map(\.kind), [.eligible, .skip(.awaitingSpaceTrigger)])
    }

    func testRecentSpaceKeyCanTriggerInitialTrailingWhitespace() {
        let context = textContext(textBeforeCursor: "Already typed ")

        let decision = evaluator.evaluate(
            context: context,
            previousContext: nil,
            compatibilityDecision: supportedCompatibilityDecision(for: context),
            lastSuggestionTriggerKeyAt: now.addingTimeInterval(-0.5),
            now: now
        )

        XCTAssertEqual(decision.outcome, .eligible)
        XCTAssertNil(decision.statusMessage)
        XCTAssertEqual(decision.logs.map(\.kind), [.eligible, .trigger(.recentSpaceKey)])
    }

    func testGoogleDocsBrailleLineTargetCountsAsSameForWhitespaceTrigger() {
        let app = AppIdentity(bundleID: "com.google.Chrome", displayName: "Chrome", processID: 1)
        let previousContext = textContext(
            app: app,
            domain: "docs.google.com",
            focusedElementID: "line-a",
            textBeforeCursor: "Docs",
            focusedElementRect: CGRect(x: 420, y: 381, width: 626, height: 1)
        )
        let currentContext = textContext(
            app: app,
            domain: "docs.google.com",
            focusedElementID: "line-b",
            textBeforeCursor: "Docs ",
            focusedElementRect: CGRect(x: 460, y: 381, width: 626, height: 1)
        )

        let decision = evaluator.evaluate(
            context: currentContext,
            previousContext: previousContext,
            compatibilityDecision: supportedCompatibilityDecision(for: currentContext),
            lastSuggestionTriggerKeyAt: .distantPast,
            now: now
        )

        XCTAssertEqual(decision.outcome, .eligible)
    }

    private func textContext(
        app: AppIdentity = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
        domain: String? = nil,
        focusedElementID: String = "field",
        textBeforeCursor: String,
        focusedElementRect: CGRect? = nil
    ) -> TextContext {
        TextContext(
            app: app,
            domain: domain,
            focusedElementID: focusedElementID,
            textBeforeCursor: textBeforeCursor,
            focusedElementRect: focusedElementRect
        )
    }

    private func supportedCompatibilityDecision(for context: TextContext) -> CompatibilityDecision {
        let profile = AppCompatibilityProfile(
            bundleID: context.app.bundleID,
            displayName: context.app.displayName,
            status: .works,
            defaultMode: .inline
        )
        return CompatibilityDecision(profile: profile, mode: .inline, enabled: true)
    }
}
