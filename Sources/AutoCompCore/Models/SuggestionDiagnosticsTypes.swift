import Foundation

/// Shared diagnostics types for Suggestion pipeline runs.
///
/// Lives in AutoCompCore so it can be recorded/aggregated in unit tests.
public enum SuggestionDiagnosticsTypes {

    /// A single diagnostic event emitted by pipeline steps.
    public struct Event: Sendable, Equatable {
        public enum Kind: String, Sendable {
            case timing
            case discard
            case provider
            case note
        }

        public let kind: Kind
        public let name: String
        public let value: String?
        public let timestamp: Date

        public init(kind: Kind, name: String, value: String? = nil, timestamp: Date = Date()) {
            self.kind = kind
            self.name = name
            self.value = value
            self.timestamp = timestamp
        }
    }

    /// Aggregated diagnostics for a pipeline run.
    public struct Report: Sendable, Equatable {
        public var events: [Event]

        public init(events: [Event] = []) {
            self.events = events
        }
    }
}
