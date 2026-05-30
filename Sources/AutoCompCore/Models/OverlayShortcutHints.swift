import Foundation

public struct OverlayShortcutHints: Equatable, Sendable {
    public var acceptNextWord: String
    public var acceptFullSuggestion: String
    public var nextSuggestion: String
    public var previousSuggestion: String
    public var dismissSuggestion: String

    public init(
        acceptNextWord: String,
        acceptFullSuggestion: String,
        nextSuggestion: String,
        previousSuggestion: String,
        dismissSuggestion: String
    ) {
        self.acceptNextWord = acceptNextWord
        self.acceptFullSuggestion = acceptFullSuggestion
        self.nextSuggestion = nextSuggestion
        self.previousSuggestion = previousSuggestion
        self.dismissSuggestion = dismissSuggestion
    }
}
