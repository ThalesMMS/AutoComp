import Foundation

public struct CompletionRequestFactory: Sendable {
    public var promptBuilder: PromptBuilder
    public var temperature: Double

    public init(
        promptBuilder: PromptBuilder = PromptBuilder(),
        temperature: Double = 0.2
    ) {
        self.promptBuilder = promptBuilder
        self.temperature = temperature
    }

    public func makeRequest(
        for context: TextContext,
        configuration: RemoteCompletionConfiguration,
        privacySettings: PrivacySettings = PrivacySettings(),
        visualContext: VisualContextSnapshot? = nil,
        clipboardContext: ClipboardContextSnapshot? = nil
    ) -> CompletionRequest {
        let allowedVisualContext = allowedVisualContext(
            visualContext,
            privacySettings: privacySettings
        )
        let allowedClipboardContext = allowedClipboardContext(
            clipboardContext,
            privacySettings: privacySettings
        )
        let prompt = promptBuilder.prompt(
            for: context,
            privacySettings: privacySettings,
            visualContext: allowedVisualContext,
            clipboardContext: allowedClipboardContext
        )
        let requestMode = promptBuilder.mode(for: context)
        let truncatedTextBeforeCursor = promptBuilder.truncatedTextBeforeCursor(for: context)
        let truncatedTextAfterCursor = promptBuilder.truncatedTextAfterCursor(for: context)
        let truncatedSelectedText = promptBuilder.truncatedSelectedText(for: context)
        let truncatedFullTextWindow = promptBuilder.truncatedFullTextWindow(for: context)
        let allowedCaptureSources = allowedCaptureSources(
            from: context.captureSources,
            privacySettings: privacySettings
        ).union(
            allowedVisualContext?.captureSources ?? []
        ).union(
            allowedClipboardContext?.captureSources ?? []
        )

        return CompletionRequest(
            contextID: context.id,
            app: context.app,
            domain: context.domain,
            prompt: prompt,
            mode: requestMode,
            truncatedTextBeforeCursor: truncatedTextBeforeCursor,
            truncatedTextAfterCursor: truncatedTextAfterCursor,
            truncatedSelectedText: truncatedSelectedText,
            truncatedFullTextWindow: truncatedFullTextWindow,
            fimSuffixInjected: requestMode == .fillInMiddle && truncatedTextAfterCursor != nil,
            allowedCaptureSources: allowedCaptureSources,
            model: configuration.model,
            maxTokens: configuration.maxTokens,
            temperature: temperature,
            visualContext: allowedVisualContext,
            clipboardContext: allowedClipboardContext,
            promptEchoCandidates: promptEchoCandidates(
                prompt: prompt,
                truncatedTextBeforeCursor: truncatedTextBeforeCursor,
                truncatedTextAfterCursor: truncatedTextAfterCursor,
                truncatedSelectedText: truncatedSelectedText,
                clipboardSummary: allowedClipboardContext?.isIncluded == true
                    ? allowedClipboardContext?.summary
                    : nil
            )
        )
    }

    private func promptEchoCandidates(
        prompt: String,
        truncatedTextBeforeCursor: String,
        truncatedTextAfterCursor: String?,
        truncatedSelectedText: String?,
        clipboardSummary: String?
    ) -> [String] {
        [prompt, truncatedTextBeforeCursor, truncatedTextAfterCursor, truncatedSelectedText, clipboardSummary]
            .compactMap { $0 }
            .filter { !$0.isEmpty }
    }

    private func allowedCaptureSources(
        from sources: Set<TextCaptureSource>,
        privacySettings: PrivacySettings
    ) -> Set<TextCaptureSource> {
        Set(sources.filter { source in
            switch source {
            case .accessibility, .keystrokeBufferLowTrust:
                return true
            case .clipboard:
                return privacySettings.clipboardContextEnabled
            case .screenOCR:
                return privacySettings.screenContextEnabled
            }
        })
    }

    private func allowedVisualContext(
        _ visualContext: VisualContextSnapshot?,
        privacySettings: PrivacySettings
    ) -> VisualContextSnapshot? {
        guard privacySettings.screenContextEnabled,
              let visualContext,
              !visualContext.isEmpty else {
            return nil
        }

        let allowedSources = allowedCaptureSources(
            from: visualContext.captureSources,
            privacySettings: privacySettings
        )
        guard !allowedSources.isEmpty else {
            return nil
        }

        return VisualContextSnapshot(
            summary: visualContext.summary,
            captureSources: allowedSources,
            createdAt: visualContext.createdAt,
            stableFieldIdentity: visualContext.stableFieldIdentity
        )
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
