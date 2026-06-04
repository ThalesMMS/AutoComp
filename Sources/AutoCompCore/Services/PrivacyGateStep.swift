import Foundation

extension SuggestionPipeline {
    public struct PrivacyGateInput: Sendable {
        public let privacySettings: PrivacySettings
        public let appBundleID: String
        public let domain: String?
        public let isSecureField: Bool

        public init(
            privacySettings: PrivacySettings,
            appBundleID: String,
            domain: String?,
            isSecureField: Bool
        ) {
            self.privacySettings = privacySettings
            self.appBundleID = appBundleID
            self.domain = domain
            self.isSecureField = isSecureField
        }
    }

    /// Gating step that applies user privacy settings and contextual privacy exclusions.
    ///
    /// This step is intentionally pure (given its inputs) and does not perform IO.
    /// Callers are expected to supply request-scoped text, privacy, and secure-field
    /// signals through `RequestContext`.
    public struct PrivacyGateStep<Payload: Sendable & Equatable>: Step {
        public typealias Input = PrivacyGateInput

        public typealias InputProvider = @Sendable (_ context: RequestContext) -> Input?

        private let input: InputProvider

        public init(input: @escaping InputProvider = Self.input(from:)) {
            self.input = input
        }

        public func handle(context: inout SuggestionPipeline.RequestContext) async -> SuggestionPipeline.Outcome<Payload> {
            guard let input = input(context) else {
                return .continue
            }

            if input.isSecureField {
                return .discard(.init(kind: .privacy, message: "secure-field"))
            }

            let decision = input.privacySettings.collectionDecision(
                appBundleID: input.appBundleID,
                domain: input.domain
            )

            guard decision.allowed else {
                return .discard(.init(kind: .privacy, message: "collection-not-allowed:\(decision.ruleSource.rawValue)"))
            }

            return .continue
        }

        public static func input(from context: RequestContext) -> Input? {
            guard let privacySettings = context.privacySettings,
                  let textContext = context.textContext else {
                return nil
            }

            return Input(
                privacySettings: privacySettings,
                appBundleID: textContext.app.bundleID,
                domain: textContext.domain,
                isSecureField: context.isSecureField
            )
        }
    }
}
