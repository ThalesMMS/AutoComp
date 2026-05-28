import Foundation

public struct PromptInputBudgets: Equatable, Sendable {
    public var continuationPrefixCharacters: Int
    public var fimPrefixCharacters: Int
    public var fimSuffixCharacters: Int
    public var selectionCharacters: Int
    public var clipboardCharacters: Int
    public var visualContextCharacters: Int
    public var fullTextWindowCharacters: Int

    public init(
        continuationPrefixCharacters: Int,
        fimPrefixCharacters: Int,
        fimSuffixCharacters: Int,
        selectionCharacters: Int,
        clipboardCharacters: Int,
        visualContextCharacters: Int,
        fullTextWindowCharacters: Int
    ) {
        self.continuationPrefixCharacters = continuationPrefixCharacters
        self.fimPrefixCharacters = fimPrefixCharacters
        self.fimSuffixCharacters = fimSuffixCharacters
        self.selectionCharacters = selectionCharacters
        self.clipboardCharacters = clipboardCharacters
        self.visualContextCharacters = visualContextCharacters
        self.fullTextWindowCharacters = fullTextWindowCharacters
    }

    public static let `default` = PromptInputBudgets(
        continuationPrefixCharacters: 1_500,
        fimPrefixCharacters: 1_200,
        fimSuffixCharacters: 700,
        selectionCharacters: 500,
        clipboardCharacters: 500,
        visualContextCharacters: 700,
        fullTextWindowCharacters: 1_500
    )

    public static func uniform(_ characterCount: Int) -> PromptInputBudgets {
        PromptInputBudgets(
            continuationPrefixCharacters: characterCount,
            fimPrefixCharacters: characterCount,
            fimSuffixCharacters: characterCount,
            selectionCharacters: characterCount,
            clipboardCharacters: characterCount,
            visualContextCharacters: characterCount,
            fullTextWindowCharacters: characterCount
        )
    }
}

public struct PromptBuilder: Sendable {
    public var budgets: PromptInputBudgets

    public init(budgets: PromptInputBudgets = .default) {
        self.budgets = budgets
    }

    public init(maxContextCharacters: Int) {
        self.init(budgets: .uniform(maxContextCharacters))
    }

    public var maxContextCharacters: Int {
        get {
            budgets.continuationPrefixCharacters
        }
        set {
            budgets = .uniform(newValue)
        }
    }

    public func mode(for context: TextContext) -> CompletionRequestMode {
        if hasUsefulText(context.textAfterCursor) || hasUsefulText(context.selectedText) {
            return .fillInMiddle
        }
        return .continuation
    }

    public func truncatedTextBeforeCursor(for context: TextContext) -> String {
        let budget = mode(for: context) == .fillInMiddle
            ? budgets.fimPrefixCharacters
            : budgets.continuationPrefixCharacters
        return String(context.textBeforeCursor.suffix(nonNegativeLimit(budget)))
    }

    public func truncatedTextAfterCursor(for context: TextContext) -> String? {
        truncatedOptionalText(context.textAfterCursor, characterLimit: budgets.fimSuffixCharacters)
    }

    public func truncatedSelectedText(for context: TextContext) -> String? {
        truncatedOptionalText(context.selectedText, characterLimit: budgets.selectionCharacters)
    }

    public func truncatedFullTextWindow(for context: TextContext) -> String? {
        truncatedOptionalText(context.fullTextWindow, characterLimit: budgets.fullTextWindowCharacters)
    }

    public func truncatedVisualContext(_ visualContext: VisualContextSnapshot?) -> VisualContextSnapshot? {
        guard let visualContext, !visualContext.isEmpty else {
            return nil
        }

        let summary = String(visualContext.summary.prefix(nonNegativeLimit(budgets.visualContextCharacters)))
        guard !summary.isEmpty else {
            return nil
        }

        return VisualContextSnapshot(
            summary: summary,
            captureSources: visualContext.captureSources,
            createdAt: visualContext.createdAt,
            stableFieldIdentity: visualContext.stableFieldIdentity
        )
    }

    public func truncatedClipboardContext(_ clipboardContext: ClipboardContextSnapshot?) -> ClipboardContextSnapshot? {
        guard let clipboardContext else {
            return nil
        }
        guard clipboardContext.isIncluded else {
            return clipboardContext
        }

        let summary = String(clipboardContext.summary.prefix(nonNegativeLimit(budgets.clipboardCharacters)))
        guard !summary.isEmpty else {
            return nil
        }

        return ClipboardContextSnapshot(
            summary: summary,
            status: clipboardContext.status,
            captureSources: clipboardContext.captureSources,
            createdAt: clipboardContext.createdAt
        )
    }

    /// The supplied visual context is expected to be privacy-filtered before rendering.
    public func prompt(
        for context: TextContext,
        privacySettings: PrivacySettings = PrivacySettings(),
        visualContext: VisualContextSnapshot? = nil,
        clipboardContext: ClipboardContextSnapshot? = nil
    ) -> String {
        let requestMode = mode(for: context)
        let trimmedContext = truncatedTextBeforeCursor(for: context)
        let trimmedSuffix = truncatedTextAfterCursor(for: context)
        let trimmedSelection = truncatedSelectedText(for: context)
        let allowedContextSources = context.captureSources
            .filter { source in
                switch source {
                case .clipboard:
                    return privacySettings.clipboardContextEnabled
                case .screenOCR:
                    return privacySettings.screenContextEnabled
                case .accessibility, .keystrokeBufferLowTrust:
                    return true
                }
            }
        let allowedVisualContext = truncatedVisualContext(visualContext)
        let privacyAllowedClipboardContext = allowedClipboardContext(
            clipboardContext,
            privacySettings: privacySettings
        )
        let allowedClipboardContext = truncatedClipboardContext(privacyAllowedClipboardContext)
        let writingPreferences = writingPreferencesBlock(privacySettings.writingPreferences)
        let sourceDescription = allowedContextSources
            .union(allowedVisualContext?.captureSources ?? [])
            .union(allowedClipboardContext?.captureSources ?? [])
            .map(\.rawValue)
            .sorted()
            .joined(separator: ", ")

        if requestMode == .fillInMiddle {
            return fillInMiddlePrompt(
                context: context,
                trimmedContext: trimmedContext,
                trimmedSuffix: trimmedSuffix,
                trimmedSelection: trimmedSelection,
                sourceDescription: sourceDescription,
                visualContext: allowedVisualContext,
                clipboardContext: allowedClipboardContext,
                writingPreferences: writingPreferences
            )
        }

        if let allowedVisualContext {
            return """
            Continue the user's current sentence or phrase. Return only the likely next words, not explanations.
            Request mode: continuation
            App: \(context.app.displayName)
            Language hint: \(context.languageHint ?? "unknown")
            Context sources: \(sourceDescription)
            \(writingPreferences)
            \(visualContextBlock(allowedVisualContext))\(clipboardBlock(allowedClipboardContext))
            Text before cursor:
            \(trimmedContext)
            Completion:
            """
        }

        return """
        Continue the user's current sentence or phrase. Return only the likely next words, not explanations.
        Request mode: continuation
        App: \(context.app.displayName)
        Language hint: \(context.languageHint ?? "unknown")
        Context sources: \(sourceDescription)
        \(writingPreferences)
        \(clipboardBlock(allowedClipboardContext))
        Text before cursor:
        \(trimmedContext)
        Completion:
        """
    }

    private func fillInMiddlePrompt(
        context: TextContext,
        trimmedContext: String,
        trimmedSuffix: String?,
        trimmedSelection: String?,
        sourceDescription: String,
        visualContext: VisualContextSnapshot?,
        clipboardContext: ClipboardContextSnapshot?,
        writingPreferences: String
    ) -> String {
        let suffix = trimmedSuffix ?? ""
        let selection = trimmedSelection ?? ""
        let optionalVisualBlock = visualContextBlock(visualContext)

        return """
        Fill in the text at the cursor between the prefix and suffix. Return only the exact text to insert at the cursor. Do not repeat the prefix, suffix, selected text, labels, quotes, or explanations.
        Request mode: fillInMiddle
        FIM suffix injected: \(trimmedSuffix == nil ? "false" : "true")
        App: \(context.app.displayName)
        Language hint: \(context.languageHint ?? "unknown")
        Context sources: \(sourceDescription)
        \(writingPreferences)
        \(optionalVisualBlock)Text before cursor (prefix):
        \(trimmedContext)
        \(clipboardBlock(clipboardContext))
        Text after cursor (suffix):
        \(suffix)
        Selected text to replace:
        \(selection)
        FIM context:
        <|fim_prefix|>
        \(trimmedContext)
        <|fim_suffix|>
        \(suffix)
        <|fim_middle|>
        Completion:
        """
    }

    private func writingPreferencesBlock(_ preferences: WritingPreferences) -> String {
        guard let promptPreview = preferences.promptPreview else {
            return ""
        }

        return """
        \(promptPreview)

        """
    }

    private func clipboardBlock(_ clipboardContext: ClipboardContextSnapshot?) -> String {
        guard let clipboardContext else {
            return ""
        }

        return """
        Clipboard context:
        \(clipboardContext.promptPreview)

        """
    }

    private func visualContextBlock(_ visualContext: VisualContextSnapshot?) -> String {
        guard let visualContext else {
            return ""
        }

        return """
        Visual context (delimited):
        <visual_context>
        \(visualContext.summary)
        </visual_context>

        """
    }

    private func truncatedOptionalText(_ text: String?, characterLimit: Int) -> String? {
        guard let text, hasUsefulText(text) else {
            return nil
        }
        return String(text.prefix(nonNegativeLimit(characterLimit)))
    }

    private func hasUsefulText(_ text: String?) -> Bool {
        text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }

    private func nonNegativeLimit(_ characterLimit: Int) -> Int {
        max(0, characterLimit)
    }

    private func allowedClipboardContext(
        _ clipboardContext: ClipboardContextSnapshot?,
        privacySettings: PrivacySettings
    ) -> ClipboardContextSnapshot? {
        guard privacySettings.clipboardContextEnabled else {
            return nil
        }
        return clipboardContext
    }
}
