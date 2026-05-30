import Foundation

extension SuggestionPipeline {
    /// A small gating step that discards work that has been cancelled or is no longer current.
    ///
    /// This mirrors the engine's early-return patterns:
    /// - `Task.isCancelled` checks
    /// - A monotonic "is current" predicate (work id, generation, etc.)
    ///
    /// The step intentionally does **not** mutate any engine state; callers can wire it
    /// in early in the pipeline to short-circuit before doing expensive work.
    public struct StaleWorkStep<Payload: Sendable & Equatable>: Step {
        public typealias IsCurrent = @Sendable (_ requestId: UUID) -> Bool

        private let isCurrent: IsCurrent
        private let shouldDiscardOnCancel: Bool

        /// - Parameters:
        ///   - isCurrent: Predicate to determine whether the request is still the "latest".
        ///   - shouldDiscardOnCancel: If `true`, cancellation results in `.discard(.cancelled)`.
        ///     This keeps cancellation semantics explicit at the pipeline boundary.
        public init(isCurrent: @escaping IsCurrent, shouldDiscardOnCancel: Bool = true) {
            self.isCurrent = isCurrent
            self.shouldDiscardOnCancel = shouldDiscardOnCancel
        }

        public func handle(context: inout SuggestionPipeline.RequestContext) async -> SuggestionPipeline.Outcome<Payload> {
            if shouldDiscardOnCancel, Task.isCancelled {
                return .discard(.cancelled)
            }

            guard isCurrent(context.requestId) else {
                return .discard(.stale)
            }

            return .continue
        }
    }
}
