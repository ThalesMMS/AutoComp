import AutoCompCore
@testable import AutoCompApp
import XCTest

@MainActor
final class SuggestionFocusChangeGuardrailTests: XCTestCase {
    func testFocusChangeHidesSuggestionAndAcceptanceIsNotAccepted() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let initialContext = TextContext(
            app: app,
            focusedElementID: "field-a",
            textBeforeCursor: "Please "
        )

        let suggestion = Suggestion(
            baseContextID: initialContext.id,
            visibleText: "continue this",
            latencyMs: 25
        )

        let contextProvider = MutableContextProvider(context: initialContext)
        let completionProvider = CountingCompletionProvider(suggestion: suggestion)
        let presenter = RecordingSuggestionPresenter()

        let engine = SuggestionEngine(
            contextProvider: contextProvider,
            completionProvider: completionProvider,
            presenter: presenter
        )

        engine.start()
        defer { engine.stop() }

        // Trigger suggestion generation.
        engine.recordCapturedInputEvent(.text(keyCode: UInt16(CapturedInputEventAdapter.spaceKeyCode), isSuggestionTrigger: true))
        try await Task.sleep(nanoseconds: 800_000_000)

        XCTAssertEqual(engine.currentSuggestion?.visibleText, "continue this")
        XCTAssertEqual(presenter.lastSuggestion?.visibleText, "continue this")

        // Simulate a focus change. SuggestionEngine listens to workspace activation/deactivation
        // and treats them as likely focus changes.
        let nextContext = TextContext(
            app: app,
            focusedElementID: "field-b",
            textBeforeCursor: "Other "
        )
        await contextProvider.updateContext(nextContext)
        NotificationCenter.default.post(name: NSWorkspace.didDeactivateApplicationNotification, object: nil)
        try await Task.sleep(nanoseconds: 250_000_000)

        XCTAssertNil(engine.currentSuggestion)
        XCTAssertNil(presenter.lastSuggestion)

        // After hide, there must be no acceptance path.
        let inserter = NoOpTextInserter()
        let outcome = await engine.acceptAll(using: inserter)
        XCTAssertNotEqual(outcome, .accepted)
    }
}

private actor MutableContextProvider: TextContextProvider {
    private var context: TextContext

    init(context: TextContext) {
        self.context = context
    }

    func updateContext(_ context: TextContext) {
        self.context = context
    }

    func currentContext() async throws -> TextContext {
        context
    }
}

private actor CountingCompletionProvider: CompletionProvider {
    private let suggestion: Suggestion
    private var storedCallCount = 0

    init(suggestion: Suggestion) {
        self.suggestion = suggestion
    }

    func getCallCount() -> Int {
        storedCallCount
    }

    func complete(context: TextContext) async throws -> Suggestion {
        storedCallCount += 1
        return suggestion
    }
}

@MainActor
private final class RecordingSuggestionPresenter: SuggestionPresenter {
    private(set) var lastSuggestion: Suggestion?

    func show(_ suggestion: Suggestion, for context: TextContext, mode: SuggestionDisplayMode) {
        lastSuggestion = suggestion
    }

    func update(_ suggestion: Suggestion, for context: TextContext, mode: SuggestionDisplayMode) {
        lastSuggestion = suggestion
    }

    func hide() {
        lastSuggestion = nil
    }
}

private enum CapturedInputEventAdapter {
    static let spaceKeyCode: Int = 49
}

@MainActor
private final class NoOpTextInserter: TextInserter {
    func insert(_ text: String) throws {}

    func acceptNextWord(from suggestion: inout Suggestion) async throws -> String? {
        // Do not mutate.
        return nil
    }

    func acceptAll(from suggestion: inout Suggestion) async throws -> String? {
        // Do not mutate.
        return nil
    }
}
