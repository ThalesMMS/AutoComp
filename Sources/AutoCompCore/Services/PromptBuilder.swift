import Foundation

public struct PromptBuilder: Sendable {
    public var maxContextCharacters: Int

    public init(maxContextCharacters: Int = 1_500) {
        self.maxContextCharacters = maxContextCharacters
    }

    /// The supplied visual context is expected to be privacy-filtered before rendering.
    public func prompt(
        for context: TextContext,
        privacySettings: PrivacySettings = PrivacySettings(),
        visualContext: VisualContextSnapshot? = nil
    ) -> String {
        let trimmedContext = String(context.textBeforeCursor.suffix(maxContextCharacters))
        let allowedContextSources = context.captureSources
            .filter { source in
                switch source {
                case .clipboard:
                    return privacySettings.clipboardContextEnabled
                case .screenOCR:
                    return privacySettings.screenContextEnabled
                case .accessibility:
                    return true
                }
            }
        let allowedVisualContext = visualContext?.isEmpty == false ? visualContext : nil
        let sourceDescription = allowedContextSources
            .union(allowedVisualContext?.captureSources ?? [])
            .map(\.rawValue)
            .sorted()
            .joined(separator: ", ")

        if let allowedVisualContext {
            return """
            Continue the user's current sentence or phrase. Return only the likely next words, not explanations.
            App: \(context.app.displayName)
            Language hint: \(context.languageHint ?? "unknown")
            Context sources: \(sourceDescription)
            Visual context:
            \(allowedVisualContext.summary)
            Text before cursor:
            \(trimmedContext)
            Completion:
            """
        }

        return """
        Continue the user's current sentence or phrase. Return only the likely next words, not explanations.
        App: \(context.app.displayName)
        Language hint: \(context.languageHint ?? "unknown")
        Context sources: \(sourceDescription)
        Text before cursor:
        \(trimmedContext)
        Completion:
        """
    }

}
