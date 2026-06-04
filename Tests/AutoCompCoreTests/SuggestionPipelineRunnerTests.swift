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

    func testRequestContextPreparesProviderInputsAndMultiSuggestionDecision() {
        let textContext = TextContext(
            app: .init(bundleID: "com.test", displayName: "Test", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: "hello"
        )
        let privacySettings = PrivacySettings(
            collectionEnabled: true,
            clipboardContextEnabled: true,
            screenContextEnabled: true
        )
        let sample = PersonalizationSample(
            excerpt: "local style",
            appBundleID: "com.test",
            domain: nil,
            languageHint: nil,
            createdAt: Date(timeIntervalSince1970: 1)
        )
        let visualContext = VisualContextSnapshot(summary: "Visible context")
        let clipboardContext = ClipboardContextSnapshot(summary: "Clipboard context", status: .included)
        var context = SuggestionPipeline.RequestContext(textContext: textContext)

        context.prepareProviderInvocation(
            privacySettings: privacySettings,
            personalizationSamples: [sample],
            visualContext: visualContext,
            clipboardContext: clipboardContext,
            requestsMultipleSuggestions: true
        )

        XCTAssertFalse(context.isLowTrustRequest)
        XCTAssertTrue(context.requestsMultipleSuggestions)
        XCTAssertEqual(context.privacySettings, privacySettings)
        XCTAssertEqual(context.personalizationSamples, [sample])
        XCTAssertEqual(context.visualContext, visualContext)
        XCTAssertEqual(context.clipboardContext, clipboardContext)
        XCTAssertEqual(context.completionOptions, CompletionOptions(suggestionCount: 3))
        XCTAssertEqual(context.providerInvocationRequest?.options, CompletionOptions(suggestionCount: 3))
    }

    func testLowTrustRequestPreparationOmitsSupplementalContext() {
        let textContext = TextContext(
            app: .init(bundleID: "com.test", displayName: "Test", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: "hello",
            captureSources: [.keystrokeBufferLowTrust]
        )
        var context = SuggestionPipeline.RequestContext(textContext: textContext)

        context.prepareProviderInvocation(
            privacySettings: PrivacySettings(clipboardContextEnabled: true, screenContextEnabled: true),
            visualContext: VisualContextSnapshot(summary: "Visible context"),
            clipboardContext: ClipboardContextSnapshot(summary: "Clipboard context", status: .included),
            requestsMultipleSuggestions: false
        )

        XCTAssertTrue(context.isLowTrustRequest)
        XCTAssertFalse(context.requestsMultipleSuggestions)
        XCTAssertNil(context.visualContext)
        XCTAssertNil(context.clipboardContext)
        XCTAssertNil(context.providerInvocationRequest?.visualContext)
        XCTAssertNil(context.providerInvocationRequest?.clipboardContext)
        XCTAssertEqual(context.completionOptions, CompletionOptions(suggestionCount: 1))
    }
}
