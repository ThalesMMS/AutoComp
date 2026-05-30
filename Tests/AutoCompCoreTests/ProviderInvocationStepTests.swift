import XCTest
@testable import AutoCompCore

final class ProviderInvocationStepTests: XCTestCase {
    func testPublishesSuggestion() async {
        let provider = FakeProvider(result: .success(.init(baseContextID: UUID(), visibleText: "hello", latencyMs: 0)))
        let step = ProviderInvocationStep(provider: provider) { _ in
            ProviderInvocation.Request(context: .init(app: .init(bundleID: "com.test", displayName: "Test", processID: 1), focusedElementID: "field", textBeforeCursor: "a", textAfterCursor: ""))
        }

        var context = SuggestionPipeline.RequestContext()
        let outcome = await step.handle(context: &context)

        switch outcome {
        case .publish(let suggestion):
            XCTAssertEqual(suggestion.visibleText, "hello")
        default:
            XCTFail("Expected publish, got: \(outcome)")
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
