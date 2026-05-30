import AutoCompCore
import CoreGraphics
@testable import AutoCompApp
import XCTest

@MainActor
final class SuggestionControllerExtractionTests: XCTestCase {
    func testInputControllerReturnsSemanticActionAndRecordsTrigger() {
        let controller = SuggestionInputController()
        let triggerAction = controller.action(
            for: .text(keyCode: CapturedInputEventAdapter.spaceKeyCode, isSuggestionTrigger: true)
        )

        XCTAssertTrue(triggerAction.shouldSchedulePrediction)
        XCTAssertFalse(triggerAction.shouldClearSuggestion)
        XCTAssertEqual(triggerAction.clearEventKind, nil)
        XCTAssertGreaterThan(controller.lastSuggestionTriggerKeyAt, .distantPast)

        let clearAction = controller.action(
            for: .text(keyCode: 51, isSuggestionTrigger: false)
        )
        XCTAssertFalse(clearAction.shouldSchedulePrediction)
        XCTAssertTrue(clearAction.shouldClearSuggestion)
        XCTAssertEqual(clearAction.clearEventKind, .textMutation)
    }

    func testLifecycleControllerStartsAndStops() {
        let controller = SuggestionLifecycleController()
        XCTAssertFalse(controller.isRunning)

        controller.start()
        XCTAssertTrue(controller.isRunning)

        controller.stop()
        XCTAssertFalse(controller.isRunning)
    }

    func testPredictionControllerInvalidatesEarlierDebouncedWork() async {
        let controller = SuggestionPredictionController(debounceInterval: 0.01)
        var firedWorkIDs: [Int] = []
        let fired = expectation(description: "latest work fired")

        let firstWorkID = controller.replaceDebouncedWork { workID in
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                firedWorkIDs.append(workID)
            }
        }
        let secondWorkID = controller.replaceDebouncedWork { workID in
            try? await Task.sleep(nanoseconds: 10_000_000)
            guard !Task.isCancelled else {
                return
            }
            await MainActor.run {
                firedWorkIDs.append(workID)
                fired.fulfill()
            }
        }

        XCTAssertNotEqual(firstWorkID, secondWorkID)
        await fulfillment(of: [fired], timeout: 1)
        XCTAssertEqual(firedWorkIDs, [secondWorkID])
        XCTAssertTrue(controller.isCurrent(secondWorkID))
    }

    func testAcceptanceControllerAcceptsNextWordAndPredictsPresentationContext() async throws {
        let context = textContext(textBeforeCursor: "Hello ")
        let suggestion = Suggestion(
            baseContextID: context.id,
            visibleText: "world again",
            latencyMs: 12
        )
        let controller = SuggestionAcceptanceController(sessionController: AcceptanceSessionController())
        let result = try await controller.acceptNextWord(
            currentSuggestion: suggestion,
            currentContext: context,
            using: RecordingTextInserter()
        )

        XCTAssertEqual(result?.acceptedText, "world ")
        XCTAssertEqual(result?.currentSuggestion?.visibleText, "again")
        XCTAssertEqual(result?.presentationContext?.textBeforeCursor, "Hello world ")
        XCTAssertEqual(result?.presentationContext?.caretRect?.origin.x, 148)
        XCTAssertFalse(result?.completedAcceptAllStateArmed ?? true)
    }

    func testDiagnosticsControllerFormatsContextAndSuggestion() {
        let context = textContext(textBeforeCursor: "Hello ")
        let suggestion = Suggestion(
            baseContextID: context.id,
            visibleText: "world",
            latencyMs: 12
        )
        let controller = SuggestionDiagnosticsController()

        let contextDescription = controller.contextDescription(context)
        XCTAssertTrue(contextDescription.contains("app=TextEdit"))
        XCTAssertTrue(contextDescription.contains("source=accessibility"))
        XCTAssertTrue(contextDescription.contains("trust=standard"))
        XCTAssertTrue(contextDescription.contains("geometry=direct"))
        XCTAssertTrue(contextDescription.contains("trailingWhitespace=true"))
        XCTAssertFalse(contextDescription.contains("Hello"))

        let suggestionDescription = controller.suggestionDescription(suggestion)
        XCTAssertTrue(suggestionDescription.contains("visibleLength=5"))
        XCTAssertTrue(suggestionDescription.contains("exhausted=false"))
    }

    private func textContext(textBeforeCursor: String) -> TextContext {
        TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: textBeforeCursor,
            caretRect: CGRect(x: 100, y: 100, width: 2, height: 20),
            caretGeometryQuality: .directCaret,
            observedCharacterWidth: 8
        )
    }
}

private final class RecordingTextInserter: TextInserter {
    private(set) var insertedTexts: [String] = []

    func insert(_ text: String) throws {
        insertedTexts.append(text)
    }

    func acceptNextWord(from suggestion: inout Suggestion) async throws -> String? {
        guard let token = suggestion.acceptNextWord() else {
            return nil
        }
        try insert(token)
        return token
    }

    func acceptAll(from suggestion: inout Suggestion) async throws -> String? {
        guard let token = suggestion.acceptAll() else {
            return nil
        }
        try insert(token)
        return token
    }
}
