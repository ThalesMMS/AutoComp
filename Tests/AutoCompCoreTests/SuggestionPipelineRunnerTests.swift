import XCTest
@testable import AutoCompCore

final class SuggestionPipelineRunnerTests: XCTestCase {
    private struct ContinueStep: SuggestionPipeline.Step {
        typealias Payload = String

        let suggestion: Suggestion

        func handle(context: inout SuggestionPipeline.RequestContext) async -> SuggestionPipeline.Outcome<String> {
            context.suggestion = suggestion
            return .continue
        }
    }

    private struct DiscardStep: SuggestionPipeline.Step {
        typealias Payload = String

        let reason: SuggestionPipeline.DiscardReason

        func handle(context: inout SuggestionPipeline.RequestContext) async -> SuggestionPipeline.Outcome<String> {
            _ = context
            return .discard(reason)
        }
    }

    func testRunnerStopsAtFirstTerminalOutcome() async {
        let suggestion = Suggestion(baseContextID: UUID(), visibleText: "first", latencyMs: 0)
        var context = SuggestionPipeline.RequestContext()

        let runner = SuggestionPipeline.Runner<String>(steps: [
            ContinueStep(suggestion: suggestion),
            DiscardStep(reason: .stale),
            ContinueStep(suggestion: Suggestion(baseContextID: UUID(), visibleText: "second", latencyMs: 0))
        ])

        let outcome = await runner.run(context: &context)

        XCTAssertEqual(outcome, .discard(.stale))
        XCTAssertEqual(context.suggestion, suggestion)
    }

    func testRunnerReturnsContinueWhenAllStepsContinue() async {
        let suggestion = Suggestion(baseContextID: UUID(), visibleText: "second", latencyMs: 0)
        var context = SuggestionPipeline.RequestContext()

        let runner = SuggestionPipeline.Runner<String>(steps: [
            ContinueStep(suggestion: Suggestion(baseContextID: UUID(), visibleText: "first", latencyMs: 0)),
            ContinueStep(suggestion: suggestion)
        ])

        let outcome = await runner.run(context: &context)

        XCTAssertEqual(outcome, .continue)
        XCTAssertEqual(context.suggestion, suggestion)
    }

    func testRequestContextBuildsTypedProviderInvocationRequest() {
        let textContext = TextContext(
            app: .init(bundleID: "com.test", displayName: "Test", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: "hello",
            textAfterCursor: " world"
        )
        let sample = PersonalizationSample(
            excerpt: "local style",
            appBundleID: "com.test",
            domain: nil,
            languageHint: nil,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let privacySettings = PrivacySettings(collectionEnabled: true)
        let context = SuggestionPipeline.RequestContext(
            textContext: textContext,
            privacySettings: privacySettings,
            personalizationSamples: [sample],
            completionOptions: CompletionOptions(suggestionCount: 3)
        )

        let request = context.providerInvocationRequest

        XCTAssertEqual(request?.context, textContext)
        XCTAssertEqual(request?.privacySettings, privacySettings)
        XCTAssertEqual(request?.personalizationSamples, [sample])
        XCTAssertEqual(request?.options, CompletionOptions(suggestionCount: 3))
    }
}
