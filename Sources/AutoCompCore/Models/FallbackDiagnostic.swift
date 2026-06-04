import Foundation

public struct FallbackDiagnostic: Equatable, Sendable {
    public enum Classification: String, Sendable {
        case deliberateFallback
        case privacyDisabled
        case optionalBuildFeature
        case platformUnavailable
        case implementationPending
    }

    public let symbol: String
    public let classification: Classification
    public let reason: String
    public let userMessage: String
    public let remediation: String?

    public init(
        symbol: String,
        classification: Classification,
        reason: String,
        userMessage: String,
        remediation: String? = nil
    ) {
        self.symbol = symbol
        self.classification = classification
        self.reason = reason
        self.userMessage = userMessage
        self.remediation = remediation
    }
}
