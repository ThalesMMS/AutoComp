import Foundation

public protocol TextContextProvider: Sendable {
    func currentContext() async throws -> TextContext
}

public protocol CompletionProvider: Sendable {
    func complete(context: TextContext) async throws -> Suggestion
}

public protocol RuntimeSwitchPreparingCompletionProvider: Sendable {
    func prepareForRuntimeSwitch() async
}

public struct CompletionOptions: Equatable, Sendable {
    public var suggestionCount: Int

    public init(suggestionCount: Int = 1) {
        self.suggestionCount = max(1, suggestionCount)
    }
}

public protocol MultipleCompletionProvider: CompletionProvider {
    func complete(
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?,
        clipboardContext: ClipboardContextSnapshot?,
        options: CompletionOptions
    ) async throws -> [Suggestion]
}

public protocol VisualContextAwareCompletionProvider: CompletionProvider {
    func complete(
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?
    ) async throws -> Suggestion
}

public protocol ClipboardContextProvider: Sendable {
    func currentClipboardContext(
        for context: TextContext,
        privacySettings: PrivacySettings
    ) -> ClipboardContextSnapshot?
}

public protocol ClipboardContextAwareCompletionProvider: VisualContextAwareCompletionProvider {
    func complete(
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?,
        clipboardContext: ClipboardContextSnapshot?
    ) async throws -> Suggestion
}

public protocol PersonalizationContextAwareCompletionProvider: ClipboardContextAwareCompletionProvider {
    func complete(
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?,
        clipboardContext: ClipboardContextSnapshot?,
        personalizationSamples: [PersonalizationSample]
    ) async throws -> Suggestion
}

public protocol MultiplePersonalizationContextAwareCompletionProvider: PersonalizationContextAwareCompletionProvider, MultipleCompletionProvider {
    func complete(
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?,
        clipboardContext: ClipboardContextSnapshot?,
        personalizationSamples: [PersonalizationSample],
        options: CompletionOptions
    ) async throws -> [Suggestion]
}

public extension VisualContextAwareCompletionProvider {
    func complete(context: TextContext) async throws -> Suggestion {
        try await complete(
            context: context,
            privacySettings: PrivacySettings(),
            visualContext: nil
        )
    }
}

public extension ClipboardContextAwareCompletionProvider {
    func complete(
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?
    ) async throws -> Suggestion {
        try await complete(
            context: context,
            privacySettings: privacySettings,
            visualContext: visualContext,
            clipboardContext: nil
        )
    }
}

public extension PersonalizationContextAwareCompletionProvider {
    func complete(
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?,
        clipboardContext: ClipboardContextSnapshot?
    ) async throws -> Suggestion {
        try await complete(
            context: context,
            privacySettings: privacySettings,
            visualContext: visualContext,
            clipboardContext: clipboardContext,
            personalizationSamples: []
        )
    }
}

public extension MultiplePersonalizationContextAwareCompletionProvider {
    func complete(
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?,
        clipboardContext: ClipboardContextSnapshot?,
        options: CompletionOptions
    ) async throws -> [Suggestion] {
        try await complete(
            context: context,
            privacySettings: privacySettings,
            visualContext: visualContext,
            clipboardContext: clipboardContext,
            personalizationSamples: [],
            options: options
        )
    }
}

@MainActor
public protocol SuggestionPresenter: AnyObject {
    func show(_ suggestion: Suggestion, for context: TextContext, mode: SuggestionDisplayMode)
    func update(_ suggestion: Suggestion, for context: TextContext, mode: SuggestionDisplayMode)
    func hide()
}

@MainActor
public protocol TextInserter: AnyObject {
    func insert(_ text: String) throws
    func acceptNextWord(from suggestion: inout Suggestion) async throws -> String?
    func acceptAll(from suggestion: inout Suggestion) async throws -> String?
}
