import AutoCompCore
import Foundation

struct CompletionRequestCoordinator {
    enum PreflightDecision: Equatable {
        case proceed(BackendStatusSummary)
        case pipelineSuspended
        case backendSuppressed(BackendStatusSummary)
    }

    struct InvocationResult {
        let outcome: SuggestionPipeline.Outcome<Suggestion>
        let backendLatencyMs: Int
    }

    func preflight(
        isPipelineSuspended: Bool,
        isAutomatic: Bool,
        backendHealthMonitor: inout BackendHealthMonitor
    ) -> PreflightDecision {
        guard !isPipelineSuspended else {
            return .pipelineSuspended
        }

        let summary = backendHealthMonitor.refresh()
        if isAutomatic, let suppression = backendHealthMonitor.suppressionSummary() {
            return .backendSuppressed(suppression)
        }
        return .proceed(summary)
    }

    func invoke(
        context: inout SuggestionPipeline.RequestContext,
        provider: any CompletionProvider,
        isCurrent: Bool,
        streamingConfiguration: StreamingCompletionConfiguration,
        streamingMetadata: StreamingCompletionMetadata,
        onPartial: @escaping @Sendable (CompletionPartial) async -> Void
    ) async -> InvocationResult {
        let runner = SuggestionPipeline.Runner<Suggestion>(steps: [
            SuggestionPipeline.StaleWorkStep<Suggestion>(isCurrent: { _ in
                isCurrent
            }),
            ProviderInvocationStep(
                provider: provider,
                timeout: CompletionBackendDefaults.providerTimeout,
                streamingConfiguration: streamingConfiguration,
                streamingMetadata: streamingMetadata,
                onPartial: onPartial
            )
        ])
        let startedAt = ContinuousClock.now
        let outcome = await runner.run(context: &context)
        return InvocationResult(
            outcome: outcome,
            backendLatencyMs: startedAt.duration(to: .now).milliseconds
        )
    }
}
