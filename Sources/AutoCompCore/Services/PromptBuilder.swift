import Foundation

public struct PromptBuilder: Sendable {
    public var maxContextCharacters: Int

    public init(maxContextCharacters: Int = 1_500) {
        self.maxContextCharacters = maxContextCharacters
    }

    public func mode(for context: TextContext) -> CompletionRequestMode {
        if hasUsefulText(context.textAfterCursor) || hasUsefulText(context.selectedText) {
            return .fillInMiddle
        }
        return .continuation
    }

    public func truncatedTextBeforeCursor(for context: TextContext) -> String {
        String(context.textBeforeCursor.suffix(maxContextCharacters))
    }

    public func truncatedTextAfterCursor(for context: TextContext) -> String? {
        truncatedOptionalText(context.textAfterCursor)
    }

    public func truncatedSelectedText(for context: TextContext) -> String? {
        truncatedOptionalText(context.selectedText)
    }

    public func truncatedFullTextWindow(for context: TextContext) -> String? {
        truncatedOptionalText(context.fullTextWindow)
    }

    /// The supplied visual context is expected to be privacy-filtered before rendering.
    public func prompt(
        for context: TextContext,
        privacySettings: PrivacySettings = PrivacySettings(),
        visualContext: VisualContextSnapshot? = nil,
        clipboardContext: ClipboardContextSnapshot? = nil
    ) -> String {
        let trimmedContext = truncatedTextBeforeCursor(for: context)
        let trimmedSuffix = truncatedTextAfterCursor(for: context)
        let trimmedSelection = truncatedSelectedText(for: context)
        let requestMode = mode(for: context)
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
        let allowedVisualContext = visualContext?.isEmpty == false ? visualContext : nil
        let allowedClipboardContext = allowedClipboardContext(
            clipboardContext,
            privacySettings: privacySettings
        )
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

    private func truncatedOptionalText(_ text: String?) -> String? {
        guard let text, hasUsefulText(text) else {
            return nil
        }
        return String(text.prefix(maxContextCharacters))
    }

    private func hasUsefulText(_ text: String?) -> Bool {
        text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
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
