import Foundation

/// A pipeline step that records diagnostic events into `SuggestionPipeline.RequestContext`.
///
/// This step is intentionally lightweight: other steps may also record events directly
/// into `context.diagnostics`, but centralizing common helpers here helps keep event
/// naming consistent.
public struct SuggestionDiagnosticsStep<Payload: Sendable & Equatable>: SuggestionPipeline.Step {

    private let now: @Sendable () -> Date
    private let stage: Stage

    public enum Stage: Sendable {
        case started
        case finished
    }

    public init(stage: Stage, now: @escaping @Sendable () -> Date = Date.init) {
        self.stage = stage
        self.now = now
    }

    public func handle(context: inout SuggestionPipeline.RequestContext) async -> SuggestionPipeline.Outcome<Payload> {
        switch stage {
        case .started:
            context.diagnostics.events.append(
                .init(kind: .note, name: SuggestionDiagnosticsEventName.pipelineStarted, timestamp: now())
            )
        case .finished:
            context.diagnostics.events.append(
                .init(kind: .note, name: SuggestionDiagnosticsEventName.pipelineFinished, timestamp: now())
            )
        }

        return .continue
    }
}

public extension SuggestionPipeline.RequestContext {
    mutating func recordDiscard(_ reason: SuggestionPipeline.DiscardReason) {
        diagnostics.events.append(
            .init(kind: .discard, name: SuggestionDiagnosticsEventName.discardReason, value: "\(reason.kind.rawValue):\(reason.message ?? "")")
        )
    }

    mutating func recordTiming(name: String, ms: Int) {
        diagnostics.events.append(
            .init(kind: .timing, name: name, value: String(ms))
        )
    }

    mutating func recordProviderMetadata(model: String?, latencyMs: Int?) {
        if let model {
            diagnostics.events.append(
                .init(kind: .provider, name: SuggestionDiagnosticsEventName.providerModel, value: model)
            )
        }
        if let latencyMs {
            diagnostics.events.append(
                .init(kind: .provider, name: SuggestionDiagnosticsEventName.providerLatencyMs, value: String(latencyMs))
            )
        }
    }
}
