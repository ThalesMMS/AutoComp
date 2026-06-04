import AutoCompCore

struct PostProviderCompletionCoordinator: Sendable {
    enum RevalidationResult: String, Equatable, Sendable {
        case skippedLowTrust = "skipped-low-trust"
        case liveContextMatched = "live-context-matched"
    }

    enum DiscardReason: String, Equatable, Sendable {
        case backendSwitchBeforeProvider = "backend-switch-before-provider"
        case missingLiveContextAfterVisual = "missing-live-context-after-visual"
        case staleVisualContext = "stale-visual-context"
        case staleWork = "stale-work"
        case missingLiveContext = "missing-live-context"
        case staleContext = "stale-context"
    }

    enum LiveRevalidationDecision: Equatable, Sendable {
        case publish(context: TextContext, revalidation: RevalidationResult)
        case discard(reason: DiscardReason, shouldRecordStaleDiscard: Bool)
    }

    enum VisualContextRevalidationDecision: Equatable, Sendable {
        case continueWithLiveContext(TextContext)
        case discard(DiscardReason)
    }

    enum BackendHealthDecision: Equatable, Sendable {
        case recordSuccess
        case recordFailure(
            message: String,
            suppressedReason: String,
            issue: BackendConnectivityIssue?
        )
    }

    enum PublicationOutcomeDecision: Equatable, Sendable {
        case bindPublishedSuggestion(Suggestion)
        case clearRejectedSuggestion(SuggestionPublicationRejectionReason)
    }

    func decideLiveRevalidation(
        requestedContext: TextContext,
        isLowTrustRequest: Bool,
        workIsCurrent: Bool,
        providerLifecycleMatches: Bool,
        liveContext: TextContext?,
        liveContextMatchesRequest: Bool
    ) -> LiveRevalidationDecision {
        guard workIsCurrent else {
            return .discard(
                reason: .staleWork,
                shouldRecordStaleDiscard: providerLifecycleMatches
            )
        }

        if isLowTrustRequest {
            return .publish(context: requestedContext, revalidation: .skippedLowTrust)
        }

        guard let liveContext else {
            return .discard(reason: .missingLiveContext, shouldRecordStaleDiscard: true)
        }

        guard liveContextMatchesRequest else {
            return .discard(reason: .staleContext, shouldRecordStaleDiscard: true)
        }

        return .publish(context: liveContext, revalidation: .liveContextMatched)
    }

    func decideVisualContextRevalidation(
        workIsCurrent: Bool,
        liveContext: TextContext?,
        visualContextMatchesLiveContext: Bool
    ) -> VisualContextRevalidationDecision {
        guard workIsCurrent else {
            return .discard(.backendSwitchBeforeProvider)
        }

        guard let liveContext else {
            return .discard(.missingLiveContextAfterVisual)
        }

        guard visualContextMatchesLiveContext else {
            return .discard(.staleVisualContext)
        }

        return .continueWithLiveContext(liveContext)
    }

    func decideBackendHealth<Payload: Equatable & Sendable>(
        for outcome: SuggestionPipeline.Outcome<Payload>
    ) -> BackendHealthDecision? {
        switch outcome {
        case .publish:
            return .recordSuccess
        case .failure(let reason):
            return .recordFailure(
                message: reason.backendIssue?.message ?? reason.message ?? "completion-failed",
                suppressedReason: reason.backendIssue?.logValue ?? reason.kind.rawValue,
                issue: reason.backendIssue
            )
        case .continue, .discard:
            return nil
        }
    }

    func decidePublicationOutcome(_ result: SuggestionPublicationResult) -> PublicationOutcomeDecision {
        switch result.outcome {
        case .published(let suggestion):
            return .bindPublishedSuggestion(suggestion)
        case .rejected(let reason):
            return .clearRejectedSuggestion(reason)
        }
    }
}
