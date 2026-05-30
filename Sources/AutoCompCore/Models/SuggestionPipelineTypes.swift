import Foundation

/// Shared types used to model SuggestionEngine request orchestration as a pipeline.
///
/// These types are intentionally minimal and live in AutoCompCore so they can be
/// unit-tested without pulling in AppKit or any UI-specific concerns.
public enum SuggestionPipeline {
    /// Immutable inputs that are expected to be stable throughout a single pipeline run.
    ///
    /// This is an initial contract; additional fields can be added incrementally as the
    /// pipeline is extracted from `SuggestionEngine`.
    public struct RequestContext: Sendable {
        public let requestId: UUID
        public let createdAt: Date

        /// Aggregated diagnostics for this pipeline run.
        public var diagnostics: SuggestionDiagnosticsTypes.Report

        /// The caller may store additional per-request values here while the contract
        /// is stabilizing. Prefer promoting commonly used values into first-class
        /// properties over time.
        public var userInfo: [String: Sendable]

        public init(
            requestId: UUID = UUID(),
            createdAt: Date = Date(),
            diagnostics: SuggestionDiagnosticsTypes.Report = .init(),
            userInfo: [String: Sendable] = [:]
        ) {
            self.requestId = requestId
            self.createdAt = createdAt
            self.diagnostics = diagnostics
            self.userInfo = userInfo
        }
    }

    /// A structured reason for discarding a request.
    ///
    /// Keep this aligned with the engine's existing early-return reasons so that
    /// logs and diagnostics can be migrated without losing fidelity.
    public struct DiscardReason: Sendable, Equatable {
        public enum Kind: String, Sendable {
            case cancelled
            case stale
            case suppressed
            case privacy
            case ineligible
            case emptyResponse
            case error
            case other
        }

        public let kind: Kind
        public let message: String?
        public let backendIssue: BackendConnectivityIssue?

        public init(
            kind: Kind,
            message: String? = nil,
            backendIssue: BackendConnectivityIssue? = nil
        ) {
            self.kind = kind
            self.message = message
            self.backendIssue = backendIssue
        }

        public static let cancelled = DiscardReason(kind: .cancelled)
        public static let stale = DiscardReason(kind: .stale)
    }

    /// The output of a pipeline step.
    public enum Outcome<Payload: Sendable>: Sendable, Equatable where Payload: Equatable {
        /// Continue to the next step.
        case `continue`

        /// Stop the pipeline and discard the request.
        case discard(DiscardReason)

        /// Stop the pipeline and publish a final payload.
        case publish(Payload)

        /// Stop the pipeline due to an error.
        case failure(DiscardReason)

        public var isTerminal: Bool {
            switch self {
            case .continue:
                return false
            case .discard, .publish, .failure:
                return true
            }
        }
    }

    /// A single pipeline step that can observe and optionally mutate the context.
    ///
    /// Steps should be small and deterministic when possible.
    public protocol Step<Payload>: Sendable {
        associatedtype Payload: Sendable & Equatable

        func handle(context: inout RequestContext) async -> Outcome<Payload>
    }

    /// Runs pipeline steps sequentially and short-circuits on terminal outcomes.
    public struct Runner<Payload: Sendable & Equatable>: Sendable {
        private let steps: [any Step<Payload>]

        public init(steps: [any Step<Payload>]) {
            self.steps = steps
        }

        public func run(context: inout RequestContext) async -> Outcome<Payload> {
            for step in steps {
                let outcome = await step.handle(context: &context)
                if outcome.isTerminal {
                    return outcome
                }
            }
            return .continue
        }
    }
}
