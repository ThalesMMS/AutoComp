import AutoCompCore
@testable import AutoCompApp
import XCTest

final class PostProviderCompletionCoordinatorTests: XCTestCase {
    func testLowTrustPublishesRequestedContextWithoutLiveRevalidation() {
        let requestedContext = textContext(textBeforeCursor: "Draft", captureSources: [.keystrokeBufferLowTrust])
        let coordinator = PostProviderCompletionCoordinator()

        let decision = coordinator.decideLiveRevalidation(
            requestedContext: requestedContext,
            isLowTrustRequest: true,
            workIsCurrent: true,
            providerLifecycleMatches: true,
            liveContext: nil,
            liveContextMatchesRequest: false
        )

        XCTAssertEqual(decision, .publish(context: requestedContext, revalidation: .skippedLowTrust))
    }

    func testStaleWorkDiscardsBeforePublication() {
        let requestedContext = textContext(textBeforeCursor: "Draft")
        let liveContext = textContext(textBeforeCursor: "Draft")
        let coordinator = PostProviderCompletionCoordinator()

        let decision = coordinator.decideLiveRevalidation(
            requestedContext: requestedContext,
            isLowTrustRequest: false,
            workIsCurrent: false,
            providerLifecycleMatches: true,
            liveContext: liveContext,
            liveContextMatchesRequest: true
        )

        XCTAssertEqual(decision, .discard(reason: .staleWork, shouldRecordStaleDiscard: true))
    }

    func testBackendSwitchStaleWorkDoesNotRecordStaleDiscardForOldProviderGeneration() {
        let requestedContext = textContext(textBeforeCursor: "Draft")
        let liveContext = textContext(textBeforeCursor: "Draft")
        let coordinator = PostProviderCompletionCoordinator()

        let decision = coordinator.decideLiveRevalidation(
            requestedContext: requestedContext,
            isLowTrustRequest: false,
            workIsCurrent: false,
            providerLifecycleMatches: false,
            liveContext: liveContext,
            liveContextMatchesRequest: true
        )

        XCTAssertEqual(decision, .discard(reason: .staleWork, shouldRecordStaleDiscard: false))
    }

    func testMissingLiveContextDiscardsBeforePublication() {
        let requestedContext = textContext(textBeforeCursor: "Draft")
        let coordinator = PostProviderCompletionCoordinator()

        let decision = coordinator.decideLiveRevalidation(
            requestedContext: requestedContext,
            isLowTrustRequest: false,
            workIsCurrent: true,
            providerLifecycleMatches: true,
            liveContext: nil,
            liveContextMatchesRequest: false
        )

        XCTAssertEqual(decision, .discard(reason: .missingLiveContext, shouldRecordStaleDiscard: true))
    }

    func testStaleLiveContextDiscardsBeforePublication() {
        let requestedContext = textContext(textBeforeCursor: "Draft")
        let liveContext = textContext(textBeforeCursor: "Different")
        let coordinator = PostProviderCompletionCoordinator()

        let decision = coordinator.decideLiveRevalidation(
            requestedContext: requestedContext,
            isLowTrustRequest: false,
            workIsCurrent: true,
            providerLifecycleMatches: true,
            liveContext: liveContext,
            liveContextMatchesRequest: false
        )

        XCTAssertEqual(decision, .discard(reason: .staleContext, shouldRecordStaleDiscard: true))
    }

    func testMatchingLiveContextPublishesLiveContext() {
        let requestedContext = textContext(textBeforeCursor: "Draft")
        let liveContext = textContext(textBeforeCursor: "Draft")
        let coordinator = PostProviderCompletionCoordinator()

        let decision = coordinator.decideLiveRevalidation(
            requestedContext: requestedContext,
            isLowTrustRequest: false,
            workIsCurrent: true,
            providerLifecycleMatches: true,
            liveContext: liveContext,
            liveContextMatchesRequest: true
        )

        XCTAssertEqual(decision, .publish(context: liveContext, revalidation: .liveContextMatched))
    }

    func testVisualContextBackendSwitchDiscardsBeforeProvider() {
        let coordinator = PostProviderCompletionCoordinator()

        let decision = coordinator.decideVisualContextRevalidation(
            workIsCurrent: false,
            liveContext: textContext(textBeforeCursor: "Draft"),
            visualContextMatchesLiveContext: true
        )

        XCTAssertEqual(decision, .discard(.backendSwitchBeforeProvider))
    }

    func testMissingLiveContextAfterVisualDiscardsBeforeProvider() {
        let coordinator = PostProviderCompletionCoordinator()

        let decision = coordinator.decideVisualContextRevalidation(
            workIsCurrent: true,
            liveContext: nil,
            visualContextMatchesLiveContext: false
        )

        XCTAssertEqual(decision, .discard(.missingLiveContextAfterVisual))
    }

    func testStaleVisualContextDiscardsBeforeProvider() {
        let liveContext = textContext(textBeforeCursor: "Draft")
        let coordinator = PostProviderCompletionCoordinator()

        let decision = coordinator.decideVisualContextRevalidation(
            workIsCurrent: true,
            liveContext: liveContext,
            visualContextMatchesLiveContext: false
        )

        XCTAssertEqual(decision, .discard(.staleVisualContext))
    }

    func testMatchingVisualContextContinuesWithLiveContext() {
        let liveContext = textContext(textBeforeCursor: "Draft")
        let coordinator = PostProviderCompletionCoordinator()

        let decision = coordinator.decideVisualContextRevalidation(
            workIsCurrent: true,
            liveContext: liveContext,
            visualContextMatchesLiveContext: true
        )

        XCTAssertEqual(decision, .continueWithLiveContext(liveContext))
    }

    func testPublishedPipelineOutcomeRecordsBackendSuccess() {
        let context = textContext(textBeforeCursor: "Draft")
        let suggestion = Suggestion(baseContextID: context.id, visibleText: " done", latencyMs: 12)
        let coordinator = PostProviderCompletionCoordinator()

        let decision = coordinator.decideBackendHealth(
            for: SuggestionPipeline.Outcome<Suggestion>.publish(suggestion)
        )

        XCTAssertEqual(decision, .recordSuccess)
    }

    func testFailurePipelineOutcomeMapsBackendIssueMessageAndSuppressionReason() {
        let coordinator = PostProviderCompletionCoordinator()
        let reason = SuggestionPipeline.DiscardReason(
            kind: .error,
            message: "transport",
            backendIssue: .timeout
        )

        let decision = coordinator.decideBackendHealth(
            for: SuggestionPipeline.Outcome<Suggestion>.failure(reason)
        )

        XCTAssertEqual(
            decision,
            .recordFailure(
                message: BackendConnectivityIssue.timeout.message,
                suppressedReason: BackendConnectivityIssue.timeout.logValue,
                issue: .timeout
            )
        )
    }

    func testFailurePipelineOutcomeFallsBackToReasonMessageWithoutBackendIssue() {
        let coordinator = PostProviderCompletionCoordinator()
        let reason = SuggestionPipeline.DiscardReason(kind: .error, message: "local failure")

        let decision = coordinator.decideBackendHealth(
            for: SuggestionPipeline.Outcome<Suggestion>.failure(reason)
        )

        XCTAssertEqual(
            decision,
            .recordFailure(message: "local failure", suppressedReason: "error", issue: nil)
        )
    }

    func testPublishedPublicationOutcomeBindsPublishedSuggestion() {
        let context = textContext(textBeforeCursor: "Draft")
        let suggestion = Suggestion(baseContextID: context.id, visibleText: " done", latencyMs: 12)
        let result = SuggestionPublicationResult(
            outcome: .published(suggestion),
            statusMessage: "Suggesting in Editor",
            lastLatencyMs: 12,
            normalizationMs: 1,
            overlayMs: 2,
            logs: []
        )
        let coordinator = PostProviderCompletionCoordinator()

        let decision = coordinator.decidePublicationOutcome(result)

        XCTAssertEqual(decision, .bindPublishedSuggestion(suggestion))
    }

    func testRejectedPublicationOutcomeClearsSuggestionWithReason() {
        let result = SuggestionPublicationResult(
            outcome: .rejected(.emptyAfterNormalization),
            statusMessage: nil,
            lastLatencyMs: nil,
            normalizationMs: 1,
            overlayMs: nil,
            logs: []
        )
        let coordinator = PostProviderCompletionCoordinator()

        let decision = coordinator.decidePublicationOutcome(result)

        XCTAssertEqual(decision, .clearRejectedSuggestion(.emptyAfterNormalization))
    }

    private func textContext(
        textBeforeCursor: String,
        captureSources: Set<TextCaptureSource> = [.accessibility]
    ) -> TextContext {
        TextContext(
            app: AppIdentity(bundleID: "com.test.editor", displayName: "Editor", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: textBeforeCursor,
            captureSources: captureSources
        )
    }
}
