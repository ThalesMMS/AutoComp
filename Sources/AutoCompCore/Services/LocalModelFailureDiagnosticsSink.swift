import Foundation

/// Captures local model load failure context so the app can generate a diagnostics report
/// and remediation steps immediately after failure.
///
/// This is intentionally lightweight and does not log prompts or user content.
public actor LocalModelFailureDiagnosticsSink {
    public static let shared = LocalModelFailureDiagnosticsSink()

    public struct Snapshot: Equatable, Sendable {
        public let recordedAt: Date
        public let errorDescription: String

        public init(recordedAt: Date, errorDescription: String) {
            self.recordedAt = recordedAt
            self.errorDescription = errorDescription
        }
    }

    private var snapshot: Snapshot?

    public init() {}

    public func record(error: Error) {
        snapshot = Snapshot(
            recordedAt: Date(),
            errorDescription: (error as? LocalizedError)?.errorDescription ?? String(describing: error)
        )
    }

    public func consumeSnapshot() -> Snapshot? {
        defer { snapshot = nil }
        return snapshot
    }

    public func peekSnapshot() -> Snapshot? {
        snapshot
    }
}
