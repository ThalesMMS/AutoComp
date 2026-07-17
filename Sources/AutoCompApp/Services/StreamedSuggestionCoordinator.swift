import AutoCompCore
import Foundation

struct StreamedSuggestionMetricsSnapshot: Equatable, Sendable {
    var partialsReceived = 0
    var partialsRendered = 0
    var partialsCoalesced = 0
    var partialsIgnored = 0
    var earlyAcceptances = 0
    var incompatibleFinals = 0
    var worksCancelledByAcceptance = 0
    var timeToFirstSafePartialMs: Int?
    var timeToFinalMs: Int?
    var overlayCostMs: [Int] = []

    var perceivedLatencyGainMs: Int? {
        guard let first = timeToFirstSafePartialMs, let final = timeToFinalMs else { return nil }
        return max(0, final - first)
    }

}

@MainActor
final class StreamedSuggestionCoordinator {
    typealias Render = @MainActor (CompletionPartial, String, TextContext) -> Void

    private struct PendingRender {
        let partial: CompletionPartial
        let text: String
        let context: TextContext
        let render: Render
    }

    private var metadata: StreamingCompletionMetadata?
    private var policy = StreamedSuggestionPolicy()
    private var pendingRender: PendingRender?
    private var drainScheduled = false
    private var drainToken = 0
    private var frozenForAcceptance = false
    private var handledFinal = false
    private(set) var metrics = StreamedSuggestionMetricsSnapshot()

    func begin(_ metadata: StreamingCompletionMetadata) {
        clear()
        self.metadata = metadata
    }

    @discardableResult
    func receive(
        _ partial: CompletionPartial,
        context: TextContext,
        render: @escaping Render
    ) -> StreamedSuggestionDecision {
        guard partial.metadata == metadata else {
            metrics.partialsIgnored += 1
            return .ignore(.outOfOrder)
        }
        if frozenForAcceptance {
            metrics.partialsReceived += 1
            metrics.partialsIgnored += 1
            if partial.isFinal {
                handledFinal = true
                metrics.timeToFinalMs = partial.latencyMs
                return .keepCurrent(.outOfOrder)
            }
            return .ignore(.outOfOrder)
        }
        metrics.partialsReceived += 1
        if partial.isFinal {
            handledFinal = true
            metrics.timeToFinalMs = partial.latencyMs
        }

        let decision = policy.evaluate(partial, context: context)
        switch decision {
        case .render(let text):
            if pendingRender != nil { metrics.partialsCoalesced += 1 }
            pendingRender = PendingRender(partial: partial, text: text, context: context, render: render)
            if metrics.timeToFirstSafePartialMs == nil {
                metrics.timeToFirstSafePartialMs = partial.latencyMs
            }
            scheduleDrain()
        case .ignore:
            metrics.partialsIgnored += 1
        case .keepCurrent:
            metrics.incompatibleFinals += 1
            terminalizePendingRender(with: partial)
        case .hide:
            metrics.incompatibleFinals += 1
            cancelPendingRender()
        case .finalizeCurrent:
            terminalizePendingRender(with: partial)
        }
        return decision
    }

    func freezeForEarlyAcceptance(_ suggestion: Suggestion?) -> Bool {
        guard let streaming = suggestion?.streamingMetadata,
              !streaming.isFinal,
              streaming.traceID == metadata?.traceContext.traceID,
              streaming.workID == metadata?.workID else {
            return false
        }
        frozenForAcceptance = true
        cancelPendingRender()
        return true
    }

    func resumeAfterFailedAcceptance() {
        frozenForAcceptance = false
    }

    func retireAfterEarlyAcceptance() {
        metrics.earlyAcceptances += 1
        metrics.worksCancelledByAcceptance += 1
        clear(keepMetrics: true)
    }

    func didHandleFinal(_ streaming: SuggestionStreamingMetadata?) -> Bool {
        guard let streaming, let metadata else { return false }
        return handledFinal
            && streaming.traceID == metadata.traceContext.traceID
            && streaming.workID == metadata.workID
    }

    func recordOverlayCost(_ milliseconds: Int) {
        metrics.overlayCostMs.append(max(0, milliseconds))
    }

    func recordRejectedBeforePolicy(_ partial: CompletionPartial) {
        guard partial.metadata == metadata else { return }
        metrics.partialsReceived += 1
        metrics.partialsIgnored += 1
        if partial.isFinal {
            handledFinal = true
            metrics.timeToFinalMs = partial.latencyMs
        }
    }

    func clear(keepMetrics: Bool = false) {
        cancelPendingRender()
        metadata = nil
        policy = StreamedSuggestionPolicy()
        frozenForAcceptance = false
        handledFinal = false
        if !keepMetrics { metrics = StreamedSuggestionMetricsSnapshot() }
    }

    private func scheduleDrain() {
        guard !drainScheduled else { return }
        drainScheduled = true
        drainToken += 1
        let scheduledToken = drainToken
        DispatchQueue.main.async { [weak self] in
            self?.drain(token: scheduledToken)
        }
    }

    private func drain(token: Int) {
        guard token == drainToken else { return }
        drainScheduled = false
        guard !frozenForAcceptance, let pendingRender else {
            self.pendingRender = nil
            return
        }
        self.pendingRender = nil
        metrics.partialsRendered += 1
        pendingRender.render(pendingRender.partial, pendingRender.text, pendingRender.context)
    }

    private func cancelPendingRender() {
        drainToken += 1
        pendingRender = nil
        drainScheduled = false
    }

    private func terminalizePendingRender(with final: CompletionPartial) {
        guard let pendingRender else { return }
        let terminal = CompletionPartial(
            metadata: final.metadata,
            accumulatedText: pendingRender.text,
            rawAccumulatedText: pendingRender.partial.rawAccumulatedText,
            providerSequence: final.providerSequence,
            route: final.route,
            phase: .final,
            latencyMs: final.latencyMs
        )
        self.pendingRender = PendingRender(
            partial: terminal,
            text: pendingRender.text,
            context: pendingRender.context,
            render: pendingRender.render
        )
    }
}
