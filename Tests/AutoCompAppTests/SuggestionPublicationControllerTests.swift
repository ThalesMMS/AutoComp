import AutoCompCore
import CoreGraphics
@testable import AutoCompApp
import XCTest

@MainActor
final class SuggestionPublicationControllerTests: XCTestCase {
    func testValidPublicationShowsSuggestionAndReturnsStatusAndLatency() {
        let presenter = RecordingSuggestionPresenter()
        let controller = SuggestionPublicationController(presenter: presenter)
        let context = textContext(textBeforeCursor: "Hello")
        let suggestion = Suggestion(
            baseContextID: context.id,
            visibleText: " there",
            latencyMs: 42
        )

        let result = controller.publish(
            suggestion,
            context: context,
            displayMode: .inline,
            collectionAllowed: false
        )

        XCTAssertEqual(result.outcome, .published(suggestion))
        XCTAssertEqual(result.statusMessage, "Suggesting in TextEdit")
        XCTAssertEqual(result.lastLatencyMs, 42)
        XCTAssertNotNil(result.normalizationMs)
        XCTAssertNotNil(result.overlayMs)
        XCTAssertGreaterThanOrEqual(result.normalizationMs ?? -1, 0)
        XCTAssertGreaterThanOrEqual(result.overlayMs ?? -1, 0)
        XCTAssertEqual(presenter.showCount, 1)
        XCTAssertEqual(presenter.hideCount, 0)
        XCTAssertEqual(presenter.lastSuggestion, suggestion)
        XCTAssertEqual(presenter.lastMode, .inline)
        XCTAssertEqual(result.logs.map(\.kind), [.published])
        XCTAssertEqual(result.logs.first?.visibleLength, 6)
    }

    func testEmptySuggestionAfterNormalizationHidesPresenterAndRejectsPublication() {
        let presenter = RecordingSuggestionPresenter()
        let controller = SuggestionPublicationController(presenter: presenter)
        let context = textContext(textBeforeCursor: "Hello ")
        let suggestion = Suggestion(
            baseContextID: context.id,
            visibleText: " \n\t",
            latencyMs: 42
        )

        let result = controller.publish(
            suggestion,
            context: context,
            displayMode: .inline,
            collectionAllowed: false
        )

        XCTAssertEqual(result.outcome, .rejected(.emptyAfterNormalization))
        XCTAssertNil(result.statusMessage)
        XCTAssertNil(result.lastLatencyMs)
        XCTAssertNotNil(result.normalizationMs)
        XCTAssertNil(result.overlayMs)
        XCTAssertGreaterThanOrEqual(result.normalizationMs ?? -1, 0)
        XCTAssertEqual(presenter.showCount, 0)
        XCTAssertEqual(presenter.hideCount, 1)
        XCTAssertEqual(result.logs.map(\.kind), [.rejected(.emptyAfterNormalization)])
        XCTAssertEqual(result.logs.first?.visibleLength, 0)
    }

    func testPublicationNormalizesLeadingWhitespaceAndUpdatesPresenter() {
        let presenter = RecordingSuggestionPresenter()
        let controller = SuggestionPublicationController(presenter: presenter)
        let context = textContext(textBeforeCursor: "Hello ")
        let suggestion = Suggestion(
            baseContextID: context.id,
            visibleText: " continue this",
            latencyMs: 24
        )

        let result = controller.publish(
            suggestion,
            context: context,
            displayMode: .mirrorWindow,
            collectionAllowed: true
        )

        XCTAssertEqual(result.publishedSuggestion?.visibleText, "continue this")
        XCTAssertEqual(result.publishedSuggestion?.remainingText, "continue this")
        XCTAssertEqual(result.statusMessage, "Suggesting in TextEdit; collection enabled")
        XCTAssertEqual(presenter.showCount, 1)
        XCTAssertEqual(presenter.lastSuggestion?.visibleText, "continue this")
        XCTAssertEqual(presenter.lastMode, .mirrorWindow)
    }

    func testMultiSuggestionPublicationStatusReportsSelectedAlternativeCount() {
        let presenter = RecordingSuggestionPresenter()
        let controller = SuggestionPublicationController(presenter: presenter)
        let context = textContext(textBeforeCursor: "Hello")
        let suggestion = Suggestion(
            baseContextID: context.id,
            visibleText: " first",
            alternatives: [
                SuggestionAlternative(visibleText: " first"),
                SuggestionAlternative(visibleText: " second"),
                SuggestionAlternative(visibleText: " third")
            ],
            selectedAlternativeIndex: 1,
            latencyMs: 42
        )

        let result = controller.publish(
            suggestion,
            context: context,
            displayMode: .inline,
            collectionAllowed: false
        )

        XCTAssertEqual(result.statusMessage, "Suggesting in TextEdit; alternative 2 of 3")
        XCTAssertEqual(presenter.lastSuggestion?.selectedAlternativeIndex, 1)
        XCTAssertEqual(presenter.lastSuggestion?.visibleText, " second")
    }

    private func textContext(textBeforeCursor: String) -> TextContext {
        TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: textBeforeCursor,
            caretRect: CGRect(x: 100, y: 100, width: 2, height: 20)
        )
    }
}

@MainActor
private final class RecordingSuggestionPresenter: SuggestionPresenter {
    private(set) var showCount = 0
    private(set) var updateCount = 0
    private(set) var hideCount = 0
    private(set) var lastSuggestion: Suggestion?
    private(set) var lastContext: TextContext?
    private(set) var lastMode: SuggestionDisplayMode?

    func show(_ suggestion: Suggestion, for context: TextContext, mode: SuggestionDisplayMode) {
        showCount += 1
        lastSuggestion = suggestion
        lastContext = context
        lastMode = mode
    }

    func update(_ suggestion: Suggestion, for context: TextContext, mode: SuggestionDisplayMode) {
        updateCount += 1
        lastSuggestion = suggestion
        lastContext = context
        lastMode = mode
    }

    func hide() {
        hideCount += 1
        lastSuggestion = nil
        lastContext = nil
        lastMode = nil
    }
}
