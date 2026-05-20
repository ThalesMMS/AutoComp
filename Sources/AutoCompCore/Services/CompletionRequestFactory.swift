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
        visualContext: VisualContextSnapshot? = nil
    ) -> CompletionRequest {
        let allowedVisualContext = allowedVisualContext(
            visualContext,
            privacySettings: privacySettings
        )
        let prompt = promptBuilder.prompt(
            for: context,
            privacySettings: privacySettings,
            visualContext: allowedVisualContext
        )
        let truncatedTextBeforeCursor = String(context.textBeforeCursor.suffix(promptBuilder.maxContextCharacters))
        let allowedCaptureSources = allowedCaptureSources(
            from: context.captureSources,
            privacySettings: privacySettings
        ).union(
            allowedVisualContext?.captureSources ?? []
        )

        return CompletionRequest(
            contextID: context.id,
            app: context.app,
            domain: context.domain,
            prompt: prompt,
            truncatedTextBeforeCursor: truncatedTextBeforeCursor,
            allowedCaptureSources: allowedCaptureSources,
            model: configuration.model,
            maxTokens: configuration.maxTokens,
            temperature: temperature,
            visualContext: allowedVisualContext,
            promptEchoCandidates: [prompt, truncatedTextBeforeCursor]
        )
    }

    private func allowedCaptureSources(
        from sources: Set<TextCaptureSource>,
        privacySettings: PrivacySettings
    ) -> Set<TextCaptureSource> {
        Set(sources.filter { source in
            switch source {
            case .accessibility:
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
            createdAt: visualContext.createdAt
        )
    }
}
