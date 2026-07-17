import Foundation
import XCTest
@testable import AutoCompCore

final class ProviderInvocationStepTests: XCTestCase {
    func testPublishesSuggestion() async {
        let textContext = Self.textContext()
        let provider = FakeProvider(result: .success(.init(baseContextID: textContext.id, visibleText: "hello", latencyMs: 0)))
        let step = ProviderInvocationStep(provider: provider)

        var context = SuggestionPipeline.RequestContext(
            textContext: textContext,
            privacySettings: PrivacySettings()
        )
        let outcome = await step.handle(context: &context)

        switch outcome {
        case .publish(let suggestion):
            XCTAssertEqual(suggestion.visibleText, "hello")
            XCTAssertEqual(context.suggestion, suggestion)
        default:
            XCTFail("Expected publish, got: \(outcome)")
        }
    }

    func testDiscardsWhenTypedProviderRequestIsMissing() async {
        let provider = FakeProvider(result: .success(.init(baseContextID: UUID(), visibleText: "hello", latencyMs: 0)))
        let step = ProviderInvocationStep(provider: provider)

        var context = SuggestionPipeline.RequestContext()
        let outcome = await step.handle(context: &context)

        switch outcome {
        case .discard(let reason):
            XCTAssertEqual(reason.kind, SuggestionPipeline.DiscardReason.Kind.ineligible)
            XCTAssertEqual(reason.message, "Missing provider request")
        default:
            XCTFail("Expected discard, got: \(outcome)")
        }
    }

    func testDiscardsEmptySuggestion() async {
        let provider = FakeProvider(result: .success(.init(baseContextID: UUID(), visibleText: "   \n", latencyMs: 0)))
        let step = ProviderInvocationStep(provider: provider) { _ in
            ProviderInvocation.Request(context: .init(app: .init(bundleID: "com.test", displayName: "Test", processID: 1), focusedElementID: "field", textBeforeCursor: "a", textAfterCursor: ""))
        }

        var context = SuggestionPipeline.RequestContext()
        let outcome = await step.handle(context: &context)

switch outcome {
        case .discard(let reason):
            XCTAssertEqual(reason.kind, SuggestionPipeline.DiscardReason.Kind.emptyResponse)
        default:
            XCTFail("Expected discard, got: \(outcome)")
        }
    }

    func testTimeoutReturnsFailure() async {
        let provider = HangingProvider(baseContextID: UUID())
        let step = ProviderInvocationStep(provider: provider, timeout: .milliseconds(10)) { _ in
            ProviderInvocation.Request(context: .init(app: .init(bundleID: "com.test", displayName: "Test", processID: 1), focusedElementID: "field", textBeforeCursor: "a", textAfterCursor: ""))
        }

        var context = SuggestionPipeline.RequestContext()
        let outcome = await step.handle(context: &context)

        switch outcome {
        case .failure(let reason):
            XCTAssertEqual(reason.kind, SuggestionPipeline.DiscardReason.Kind.error)
        default:
            XCTFail("Expected failure, got: \(outcome)")
        }
    }

    func testProviderErrorIsMappedToFailure() async {
        struct TestError: Error {}

        let provider = FakeProvider(result: .failure(TestError()))
        let step = ProviderInvocationStep(provider: provider) { _ in
            ProviderInvocation.Request(context: .init(app: .init(bundleID: "com.test", displayName: "Test", processID: 1), focusedElementID: "field", textBeforeCursor: "a", textAfterCursor: ""))
        }

        var context = SuggestionPipeline.RequestContext()
        let outcome = await step.handle(context: &context)

        switch outcome {
        case .failure(let reason):
            XCTAssertEqual(reason.kind, SuggestionPipeline.DiscardReason.Kind.error)
        default:
            XCTFail("Expected failure, got: \(outcome)")
        }
    }

    func testForwardsPersonalizationSamplesToAwareProvider() async {
        let provider = PersonalizationRecordingProvider()
        let sample = PersonalizationSample(
            excerpt: "local style sample",
            appBundleID: "com.test",
            domain: nil,
            languageHint: nil,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let step = ProviderInvocationStep(provider: provider)

        var context = SuggestionPipeline.RequestContext(
            textContext: Self.textContext(),
            privacySettings: PrivacySettings(),
            personalizationSamples: [sample]
        )
        let outcome = await step.handle(context: &context)

        switch outcome {
        case .publish(let suggestion):
            XCTAssertEqual(suggestion.visibleText, "personalized")
        default:
            XCTFail("Expected publish, got: \(outcome)")
        }

        let recordedSamples = await provider.recordedSamples()
        XCTAssertEqual(recordedSamples, [sample])
    }

    func testCancellationDiscardsCancelled() async {
        let provider = HangingProvider(baseContextID: UUID())
        let step = ProviderInvocationStep(provider: provider, timeout: nil) { _ in
            ProviderInvocation.Request(context: .init(app: .init(bundleID: "com.test", displayName: "Test", processID: 1), focusedElementID: "field", textBeforeCursor: "a", textAfterCursor: ""))
        }

        var context = SuggestionPipeline.RequestContext()
        let task = Task { await step.handle(context: &context) }
        task.cancel()
        let outcome = await task.value

switch outcome {
        case .discard(let reason):
            XCTAssertEqual(reason, SuggestionPipeline.DiscardReason.cancelled)
        default:
            XCTFail("Expected cancelled discard, got: \(outcome)")
        }
    }

    func testStreamingCapabilityEmitsPartialsAndPublishesFinal() async {
        let textContext = Self.textContext()
        let trace = CompletionTraceContext()
        let metadata = StreamingCompletionMetadata(
            traceContext: trace,
            workID: 42,
            requestedRoute: .localLlama
        )
        let provider = FakeStreamingProvider(textContext: textContext, metadata: metadata)
        let collector = PartialCollector()
        let step = ProviderInvocationStep(
            provider: provider,
            streamingConfiguration: .init(enabledRoutes: [.localLlama]),
            streamingMetadata: metadata,
            onPartial: { partial in await collector.append(partial) }
        )
        var context = SuggestionPipeline.RequestContext(
            textContext: textContext,
            privacySettings: PrivacySettings()
        )

        let outcome = await step.handle(context: &context)

        guard case .publish(let suggestion) = outcome else {
            return XCTFail("Expected streamed publish, got: \(outcome)")
        }
        XCTAssertEqual(suggestion.visibleText, "hello")
        XCTAssertEqual(suggestion.streamingMetadata?.workID, 42)
        XCTAssertTrue(suggestion.streamingMetadata?.isFinal == true)
        let partialTexts = await collector.values().map(\.accumulatedText)
        let nonStreamingCalls = await provider.nonStreamingCallCount()
        XCTAssertEqual(partialTexts, ["hel", "hello"])
        XCTAssertEqual(nonStreamingCalls, 0)
    }

    func testStreamingDisabledUsesExistingNonStreamingPath() async {
        let textContext = Self.textContext()
        let metadata = StreamingCompletionMetadata(
            traceContext: CompletionTraceContext(),
            workID: 7,
            requestedRoute: .localLlama
        )
        let provider = FakeStreamingProvider(textContext: textContext, metadata: metadata)
        let step = ProviderInvocationStep(
            provider: provider,
            streamingConfiguration: .disabled,
            streamingMetadata: metadata
        )
        var context = SuggestionPipeline.RequestContext(
            textContext: textContext,
            privacySettings: PrivacySettings()
        )

        let outcome = await step.handle(context: &context)

        guard case .publish(let suggestion) = outcome else {
            return XCTFail("Expected non-streaming publish, got: \(outcome)")
        }
        XCTAssertEqual(suggestion.visibleText, "fallback")
        let nonStreamingCalls = await provider.nonStreamingCallCount()
        XCTAssertEqual(nonStreamingCalls, 1)
    }

    private static func textContext() -> TextContext {
        TextContext(
            app: .init(bundleID: "com.test", displayName: "Test", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: "a",
            textAfterCursor: ""
        )
    }
}

private actor PartialCollector {
    private var partials: [CompletionPartial] = []

    func append(_ partial: CompletionPartial) { partials.append(partial) }
    func values() -> [CompletionPartial] { partials }
}

private actor FakeStreamingProvider: StreamingCompletionProvider {
    nonisolated let streamingCompletionCapability: StreamingCompletionCapability? = .init(route: .localLlama)
    nonisolated private let metadata: StreamingCompletionMetadata
    private var completionCalls = 0

    init(textContext: TextContext, metadata: StreamingCompletionMetadata) {
        self.metadata = metadata
    }

    func nonStreamingCallCount() -> Int { completionCalls }

    func complete(context: TextContext) async throws -> Suggestion {
        completionCalls += 1
        return Suggestion(baseContextID: context.id, visibleText: "fallback", latencyMs: 10)
    }

    nonisolated func streamCompletion(
        request: ProviderInvocation.Request,
        metadata: StreamingCompletionMetadata
    ) -> AsyncThrowingStream<CompletionPartial, Error> {
        let expectedMetadata = self.metadata
        return AsyncThrowingStream { continuation in
            let route = CompletionRoute(requestedKind: .localLlama, deliveredKind: .localLlama)
            continuation.yield(CompletionPartial(
                metadata: expectedMetadata,
                accumulatedText: "hel",
                providerSequence: 1,
                route: route,
                phase: .partial,
                latencyMs: 3
            ))
            continuation.yield(CompletionPartial(
                metadata: expectedMetadata,
                accumulatedText: "hello",
                providerSequence: 2,
                route: route,
                phase: .final,
                latencyMs: 8
            ))
            continuation.finish()
        }
    }
}

private struct FakeProvider: CompletionProvider {
    let baseContextID: UUID = UUID()
    let result: Result<Suggestion, Error>

    func complete(context: TextContext) async throws -> Suggestion {
        switch result {
        case .success(let suggestion):
            return suggestion
        case .failure(let error):
            throw error
        }
    }
}

private struct HangingProvider: CompletionProvider {
    let baseContextID: UUID

    func complete(context: TextContext) async throws -> Suggestion {
        try await Task.sleep(for: .seconds(60))
        return Suggestion(baseContextID: baseContextID, visibleText: "never", latencyMs: 0)
    }
}

private actor PersonalizationRecordingProvider: PersonalizationContextAwareCompletionProvider {
    private var samples: [PersonalizationSample] = []

    func recordedSamples() -> [PersonalizationSample] {
        samples
    }

    func complete(
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?,
        clipboardContext: ClipboardContextSnapshot?,
        personalizationSamples: [PersonalizationSample]
    ) async throws -> Suggestion {
        samples = personalizationSamples
        return Suggestion(baseContextID: context.id, visibleText: "personalized", latencyMs: 0)
    }
}
