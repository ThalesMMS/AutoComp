import AutoCompCore
import CoreGraphics
@testable import AutoCompApp
import XCTest

@MainActor
final class AcceptanceSessionControllerTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 1_000)

    func testAcceptedSuggestionConsistencyUsesRecordedSession() {
        let controller = AcceptanceSessionController()
        let previousContext = textContext(textBeforeCursor: "Please ")
        let previousSuggestion = Suggestion(
            baseContextID: previousContext.id,
            visibleText: "continue this",
            latencyMs: 20
        )
        var updatedSuggestion = previousSuggestion
        let acceptedText = updatedSuggestion.acceptNextWord()!

        controller.recordAcceptance(
            previousContext: previousContext,
            previousSuggestion: previousSuggestion,
            updatedSuggestion: updatedSuggestion,
            acceptedText: acceptedText,
            now: now
        )

        let observedContext = textContext(textBeforeCursor: "Please continue ")
        XCTAssertTrue(
            controller.isTextConsistentWithAcceptedSuggestion(
                context: observedContext,
                previousContext: previousContext,
                suggestion: updatedSuggestion
            )
        )
    }

    func testTypedThroughSessionAdvancesRemainingSuggestion() {
        let controller = AcceptanceSessionController()
        let previousContext = textContext(textBeforeCursor: "Please ")
        let previousSuggestion = Suggestion(
            baseContextID: previousContext.id,
            visibleText: "continue this",
            latencyMs: 20
        )
        var updatedSuggestion = previousSuggestion
        let acceptedText = updatedSuggestion.acceptNextWord()!
        controller.recordAcceptance(
            previousContext: previousContext,
            previousSuggestion: previousSuggestion,
            updatedSuggestion: updatedSuggestion,
            acceptedText: acceptedText,
            now: now
        )

        let observedContext = textContext(textBeforeCursor: "Please continue t")
        let result = controller.handleAcceptedSuggestionSession(
            context: observedContext,
            currentSuggestion: updatedSuggestion,
            now: now.addingTimeInterval(0.5)
        )

        XCTAssertEqual(
            result,
            .handled(
                AcceptanceSessionHandledResult(
                    currentSuggestion: Suggestion(
                        id: updatedSuggestion.id,
                        baseContextID: updatedSuggestion.baseContextID,
                        visibleText: "his",
                        remainingText: "his",
                        acceptedPrefix: "continue t",
                        createdAt: updatedSuggestion.createdAt,
                        latencyMs: updatedSuggestion.latencyMs
                    ),
                    statusMessage: "Continuing accepted suggestion"
                )
            )
        )
    }

    func testPublishedSuggestionTypedThroughBeforeAcceptanceAdvancesRemainingSuggestion() {
        let controller = AcceptanceSessionController()
        let publishedContext = textContext(textBeforeCursor: "Please ")
        let suggestion = Suggestion(
            baseContextID: publishedContext.id,
            visibleText: "continue this",
            latencyMs: 20
        )
        controller.recordPublication(
            context: publishedContext,
            suggestion: suggestion,
            now: now
        )

        let observedContext = textContext(textBeforeCursor: "Please c")
        let result = controller.handleAcceptedSuggestionSession(
            context: observedContext,
            currentSuggestion: suggestion,
            now: now.addingTimeInterval(0.5)
        )

        XCTAssertEqual(
            result,
            .handled(
                AcceptanceSessionHandledResult(
                    currentSuggestion: Suggestion(
                        id: suggestion.id,
                        baseContextID: suggestion.baseContextID,
                        visibleText: "ontinue this",
                        remainingText: "ontinue this",
                        acceptedPrefix: "c",
                        createdAt: suggestion.createdAt,
                        latencyMs: suggestion.latencyMs
                    ),
                    statusMessage: "Continuing accepted suggestion"
                )
            )
        )
    }

    func testPublishedSuggestionDivergenceClearsSession() {
        let controller = AcceptanceSessionController()
        let publishedContext = textContext(textBeforeCursor: "Please ")
        let suggestion = Suggestion(
            baseContextID: publishedContext.id,
            visibleText: "continue this",
            latencyMs: 20
        )
        controller.recordPublication(
            context: publishedContext,
            suggestion: suggestion,
            now: now
        )

        let divergentContext = textContext(textBeforeCursor: "Please x")
        XCTAssertEqual(
            controller.handleAcceptedSuggestionSession(
                context: divergentContext,
                currentSuggestion: suggestion,
                now: now.addingTimeInterval(0.5)
            ),
            .cleared
        )
        XCTAssertEqual(
            controller.handleAcceptedSuggestionSession(
                context: textContext(textBeforeCursor: "Please c"),
                currentSuggestion: suggestion,
                now: now.addingTimeInterval(1)
            ),
            .notActive
        )
    }

    func testPublishedSuggestionFocusChangeClearsSession() {
        let controller = AcceptanceSessionController()
        let publishedContext = textContext(
            textBeforeCursor: "Please ",
            focusedElementID: "field-a",
            focusedElementRect: CGRect(x: 100, y: 100, width: 500, height: 40)
        )
        let suggestion = Suggestion(
            baseContextID: publishedContext.id,
            visibleText: "continue this",
            latencyMs: 20
        )
        controller.recordPublication(
            context: publishedContext,
            suggestion: suggestion,
            now: now
        )

        let changedFocusContext = textContext(
            textBeforeCursor: "Please c",
            focusedElementID: "field-b",
            focusedElementRect: CGRect(x: 700, y: 100, width: 500, height: 40)
        )
        XCTAssertEqual(
            controller.handleAcceptedSuggestionSession(
                context: changedFocusContext,
                currentSuggestion: suggestion,
                now: now.addingTimeInterval(0.5)
            ),
            .cleared
        )
    }

    func testPublishedSuggestionSelectionClearsSession() {
        let controller = AcceptanceSessionController()
        let publishedContext = textContext(textBeforeCursor: "Please ")
        let suggestion = Suggestion(
            baseContextID: publishedContext.id,
            visibleText: "continue this",
            latencyMs: 20
        )
        controller.recordPublication(
            context: publishedContext,
            suggestion: suggestion,
            now: now
        )

        let selectedContext = textContext(
            textBeforeCursor: "Please c",
            selectedRange: NSRange(location: 7, length: 1)
        )
        XCTAssertEqual(
            controller.handleAcceptedSuggestionSession(
                context: selectedContext,
                currentSuggestion: suggestion,
                now: now.addingTimeInterval(0.5)
            ),
            .cleared
        )
    }

    func testPublishedSuggestionExhaustionEndsSession() {
        let controller = AcceptanceSessionController()
        let publishedContext = textContext(textBeforeCursor: "Please ")
        let suggestion = Suggestion(
            baseContextID: publishedContext.id,
            visibleText: "go",
            latencyMs: 20
        )
        controller.recordPublication(
            context: publishedContext,
            suggestion: suggestion,
            now: now
        )

        let exhaustedContext = textContext(textBeforeCursor: "Please go")
        XCTAssertEqual(
            controller.handleAcceptedSuggestionSession(
                context: exhaustedContext,
                currentSuggestion: suggestion,
                now: now.addingTimeInterval(0.5)
            ),
            .handled(
                AcceptanceSessionHandledResult(
                    currentSuggestion: nil,
                    statusMessage: "Continuing accepted suggestion"
                )
            )
        )
        XCTAssertEqual(
            controller.handleAcceptedSuggestionSession(
                context: exhaustedContext,
                currentSuggestion: nil,
                now: now.addingTimeInterval(1)
            ),
            .notActive
        )
    }

    func testCompletedAcceptAllHandlesDelayedEchoWithinGrace() {
        let controller = AcceptanceSessionController()
        let previousContext = textContext(textBeforeCursor: "Please ")
        let previousSuggestion = Suggestion(
            baseContextID: previousContext.id,
            visibleText: "finish the sentence",
            latencyMs: 20
        )
        var exhaustedSuggestion = previousSuggestion
        let acceptedText = exhaustedSuggestion.acceptAll()!
        controller.recordAcceptance(
            previousContext: previousContext,
            previousSuggestion: previousSuggestion,
            updatedSuggestion: exhaustedSuggestion,
            acceptedText: acceptedText,
            now: now
        )

        XCTAssertTrue(controller.armCompletedAcceptAll())
        let delayedEchoContext = textContext(textBeforeCursor: "Please ")
        XCTAssertEqual(
            controller.repairCompletedAcceptAllLeakIfNeeded(
                context: delayedEchoContext,
                now: now.addingTimeInterval(1)
            ),
            .handled
        )
    }

    func testLeakedShortcutRepairReplacesTabAndRecordsAcceptance() async throws {
        let controller = AcceptanceSessionController()
        let previousContext = textContext(textBeforeCursor: "Please ")
        let leakedContext = textContext(textBeforeCursor: "Please \t")
        let repairer = RecordingShortcutLeakRepairer()
        let suggestion = Suggestion(
            baseContextID: previousContext.id,
            visibleText: "continue this",
            latencyMs: 20
        )

        let result = await controller.repairLeakedShortcutIfNeeded(
            context: leakedContext,
            previousContext: previousContext,
            currentSuggestion: suggestion,
            repairInserter: repairer
        )

        XCTAssertEqual(repairer.deletedLength, 1)
        XCTAssertEqual(repairer.acceptedText, "continue ")
        guard case .repaired(let repairedContext, let updatedSuggestion, let statusMessage) = result else {
            return XCTFail("Expected leaked shortcut repair")
        }
        XCTAssertEqual(repairedContext.textBeforeCursor, "Please continue ")
        XCTAssertEqual(updatedSuggestion?.visibleText, "this")
        XCTAssertEqual(statusMessage, "Accepted leaked Tab")
    }

    private func textContext(
        textBeforeCursor: String,
        focusedElementID: String = "field",
        selectedRange: NSRange? = NSRange(location: 0, length: 0),
        focusedElementRect: CGRect = CGRect(x: 100, y: 100, width: 500, height: 40)
    ) -> TextContext {
        TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: focusedElementID,
            textBeforeCursor: textBeforeCursor,
            selectedRange: selectedRange,
            focusedElementRect: focusedElementRect
        )
    }
}

@MainActor
private final class RecordingShortcutLeakRepairer: ShortcutLeakRepairing {
    private(set) var deletedLength: Int?
    private(set) var acceptedText: String?

    func replaceLeakedShortcutSuffix(
        length: Int,
        withNextWordsFrom suggestion: inout Suggestion
    ) async throws -> String? {
        deletedLength = length
        acceptedText = suggestion.acceptNextWord()
        return acceptedText
    }
}
