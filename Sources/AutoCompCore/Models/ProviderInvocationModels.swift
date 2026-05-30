import Foundation

public enum ProviderInvocation {
    /// Minimal, pipeline-friendly representation of what we send to a completion provider.
    ///
    /// This is intentionally aligned with existing provider APIs (`CompletionProvider` and
    /// `MultipleCompletionProvider`) so the provider invocation step can map 1:1.
    public struct Request: Sendable, Equatable {
        public let context: TextContext
        public let privacySettings: PrivacySettings
        public let visualContext: VisualContextSnapshot?
        public let clipboardContext: ClipboardContextSnapshot?
        public let options: CompletionOptions

        public init(
            context: TextContext,
            privacySettings: PrivacySettings = PrivacySettings(),
            visualContext: VisualContextSnapshot? = nil,
            clipboardContext: ClipboardContextSnapshot? = nil,
            options: CompletionOptions = CompletionOptions()
        ) {
            self.context = context
            self.privacySettings = privacySettings
            self.visualContext = visualContext
            self.clipboardContext = clipboardContext
            self.options = options
        }
    }

    /// Provider response envelope.
    public struct Response: Sendable, Equatable {
        public let suggestions: [Suggestion]

        public init(suggestions: [Suggestion]) {
            self.suggestions = suggestions
        }

        public var firstSuggestion: Suggestion? { suggestions.first }
        public var isEmpty: Bool { suggestions.isEmpty }
    }
}
