import Foundation

public protocol TextContextProvider: Sendable {
    func currentContext() async throws -> TextContext
}

public protocol CompletionProvider: Sendable {
    func complete(context: TextContext) async throws -> Suggestion
}

@MainActor
public protocol SuggestionPresenter: AnyObject {
    func show(_ suggestion: Suggestion, for context: TextContext, mode: SuggestionDisplayMode)
    func update(_ suggestion: Suggestion, for context: TextContext, mode: SuggestionDisplayMode)
    func hide()
}

@MainActor
public protocol TextInserter: AnyObject {
    func acceptNextWord(from suggestion: inout Suggestion) async throws -> String?
    func acceptAll(from suggestion: inout Suggestion) async throws -> String?
}
