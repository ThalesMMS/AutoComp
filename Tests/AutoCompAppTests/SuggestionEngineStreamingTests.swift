import AutoCompCore
import XCTest
@testable import AutoCompApp

@MainActor
final class SuggestionEngineStreamingTests: XCTestCase {
    func testCapableLocalProviderPublishesOneSuggestionAndUpdatesItMonotonically() async throws {
        let context = TextContext(
            app: .init(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: "Say ",
            textAfterCursor: ""
        )
        let presenter = StreamingRecordingPresenter()
        let engine = SuggestionEngine(
            contextProvider: StreamingContextProvider(context),
            completionProvider: DelayedStreamingProvider(),
            presenter: presenter,
            streamingConfiguration: .init(enabledRoutes: [.localLlama])
        )

        engine.recordCapturedInputEvent(.text(
            keyCode: CapturedInputEventAdapter.spaceKeyCode,
            isSuggestionTrigger: true
        ))

        try await waitUntil { presenter.shownTexts == ["hel"] }
        XCTAssertEqual(engine.currentSuggestion?.streamingMetadata?.isFinal, false)
        try await waitUntil { engine.currentSuggestion?.streamingMetadata?.isFinal == true }

        XCTAssertEqual(presenter.shownTexts, ["hel"])
        XCTAssertEqual(presenter.updatedTexts, ["hello"])
        XCTAssertEqual(engine.currentSuggestion?.visibleText, "hello")
        engine.stop()
    }

    func testAcceptingPartialCancelsLateFinal() async throws {
        let context = TextContext(
            app: .init(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: "Say ",
            textAfterCursor: ""
        )
        let presenter = StreamingRecordingPresenter()
        let engine = SuggestionEngine(
            contextProvider: StreamingContextProvider(context),
            completionProvider: DelayedStreamingProvider(),
            presenter: presenter,
            streamingConfiguration: .init(enabledRoutes: [.localLlama])
        )
        let inserter = StreamingTextInserter()

        engine.recordCapturedInputEvent(.text(
            keyCode: CapturedInputEventAdapter.spaceKeyCode,
            isSuggestionTrigger: true
        ))
        try await waitUntil { presenter.shownTexts == ["hel"] }

        let outcome = await engine.acceptAll(using: inserter)
        try await Task.sleep(nanoseconds: 300_000_000)

        XCTAssertEqual(outcome, .accepted)
        XCTAssertEqual(inserter.insertedText, "hel")
        XCTAssertNil(engine.currentSuggestion)
        XCTAssertEqual(presenter.updatedTexts, [])
        engine.stop()
    }

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let startedAt = ContinuousClock.now
        while !condition() {
            if startedAt.duration(to: .now) > .nanoseconds(Int64(timeoutNanoseconds)) {
                XCTFail("Timed out waiting for streaming state")
                return
            }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
    }
}

private actor StreamingContextProvider: TextContextProvider {
    private let context: TextContext
    init(_ context: TextContext) { self.context = context }
    func currentContext() async throws -> TextContext { context }
}

private struct DelayedStreamingProvider: StreamingCompletionProvider, CompletionRoutingProviding {
    let routingPolicy = CompletionRoutingPolicy(activeKind: .localLlama, fallbackKind: nil)
    let streamingCompletionCapability: StreamingCompletionCapability? = .init(route: .localLlama)

    func complete(context: TextContext) async throws -> Suggestion {
        Suggestion(baseContextID: context.id, visibleText: "fallback", latencyMs: 1)
    }

    func streamCompletion(
        request: ProviderInvocation.Request,
        metadata: StreamingCompletionMetadata
    ) -> AsyncThrowingStream<CompletionPartial, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let route = CompletionRoute(requestedKind: .localLlama, deliveredKind: .localLlama)
                continuation.yield(.init(
                    metadata: metadata,
                    accumulatedText: "hel",
                    providerSequence: 1,
                    route: route,
                    phase: .partial,
                    latencyMs: 10
                ))
                try? await Task.sleep(nanoseconds: 150_000_000)
                guard !Task.isCancelled else { return }
                continuation.yield(.init(
                    metadata: metadata,
                    accumulatedText: "hello",
                    providerSequence: 2,
                    route: route,
                    phase: .final,
                    latencyMs: 160
                ))
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@MainActor
private final class StreamingRecordingPresenter: SuggestionPresenter {
    private(set) var shownTexts: [String] = []
    private(set) var updatedTexts: [String] = []

    func show(_ suggestion: Suggestion, for context: TextContext, mode: SuggestionDisplayMode) {
        shownTexts.append(suggestion.visibleText)
    }

    func update(_ suggestion: Suggestion, for context: TextContext, mode: SuggestionDisplayMode) {
        updatedTexts.append(suggestion.visibleText)
    }

    func hide() {}
}

@MainActor
private final class StreamingTextInserter: TextInserter {
    private(set) var insertedText = ""

    func insert(_ text: String) throws { insertedText += text }

    func acceptNextWord(from suggestion: inout Suggestion) async throws -> String? {
        guard let text = suggestion.acceptNextWord() else { return nil }
        try insert(text)
        return text
    }

    func acceptAll(from suggestion: inout Suggestion) async throws -> String? {
        guard let text = suggestion.acceptAll() else { return nil }
        try insert(text)
        return text
    }
}
