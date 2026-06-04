import Foundation

/// Shared types used to model suggestion request orchestration as a pipeline.
public enum SuggestionPipeline {
    /// Request-scoped data shared between deterministic pipeline steps.
    public struct RequestContext: Sendable {
        public let requestId: UUID
        public let createdAt: Date
        public var textContext: TextContext?
        public var privacySettings: PrivacySettings?
        public var isSecureField: Bool
        public var visualContext: VisualContextSnapshot?
        public var clipboardContext: ClipboardContextSnapshot?
        public var personalizationSamples: [PersonalizationSample]
        public var requestsMultipleSuggestions: Bool
        public var completionOptions: CompletionOptions
        public var visualContextEligibilityDecision: VisualContextEligibilityDecision?
        public var suggestion: Suggestion?

        /// Aggregated diagnostics for this pipeline run.
        public var diagnostics: SuggestionDiagnosticsTypes.Report

        public init(
            requestId: UUID = UUID(),
            createdAt: Date = Date(),
            textContext: TextContext? = nil,
            privacySettings: PrivacySettings? = nil,
            isSecureField: Bool = false,
            visualContext: VisualContextSnapshot? = nil,
            clipboardContext: ClipboardContextSnapshot? = nil,
            personalizationSamples: [PersonalizationSample] = [],
            requestsMultipleSuggestions: Bool? = nil,
            completionOptions: CompletionOptions = CompletionOptions(),
            visualContextEligibilityDecision: VisualContextEligibilityDecision? = nil,
            suggestion: Suggestion? = nil,
            diagnostics: SuggestionDiagnosticsTypes.Report = .init()
        ) {
            self.requestId = requestId
            self.createdAt = createdAt
            self.textContext = textContext
            self.privacySettings = privacySettings
            self.isSecureField = isSecureField
            self.visualContext = visualContext
            self.clipboardContext = clipboardContext
            self.personalizationSamples = personalizationSamples
            self.requestsMultipleSuggestions = requestsMultipleSuggestions ?? (completionOptions.suggestionCount > 1)
            self.completionOptions = completionOptions
            self.visualContextEligibilityDecision = visualContextEligibilityDecision
            self.suggestion = suggestion
            self.diagnostics = diagnostics
        }

        public var isLowTrustRequest: Bool {
            textContext?.captureSources == [.keystrokeBufferLowTrust]
        }

        public mutating func prepareProviderInvocation(
            privacySettings: PrivacySettings,
            personalizationSamples: [PersonalizationSample] = [],
            visualContext: VisualContextSnapshot? = nil,
            clipboardContext: ClipboardContextSnapshot? = nil,
            requestsMultipleSuggestions: Bool = false
        ) {
            self.privacySettings = privacySettings
            self.personalizationSamples = personalizationSamples
            self.requestsMultipleSuggestions = requestsMultipleSuggestions
            self.completionOptions = CompletionOptions(suggestionCount: requestsMultipleSuggestions ? 3 : 1)

            guard !isLowTrustRequest else {
                self.visualContext = nil
                self.clipboardContext = nil
                return
            }

            self.visualContext = visualContext
            self.clipboardContext = clipboardContext
        }

        public var providerInvocationRequest: ProviderInvocation.Request? {
            guard let textContext, let privacySettings else {
                return nil
            }

            return ProviderInvocation.Request(
                context: textContext,
                privacySettings: privacySettings,
                visualContext: visualContext,
                clipboardContext: clipboardContext,
                personalizationSamples: personalizationSamples,
                options: completionOptions
            )
        }
    }

    public enum VisualContextEligibilityDecision: Sendable, Equatable {
        case eligible
        case ineligible(reason: String)
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
