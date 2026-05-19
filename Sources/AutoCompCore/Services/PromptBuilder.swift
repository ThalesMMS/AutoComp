import Foundation

public struct PromptBuilder: Sendable {
    public var maxContextCharacters: Int

    public init(maxContextCharacters: Int = 1_500) {
        self.maxContextCharacters = maxContextCharacters
    }

    public func prompt(for context: TextContext, privacySettings: PrivacySettings = PrivacySettings()) -> String {
        let trimmedContext = String(context.textBeforeCursor.suffix(maxContextCharacters))
        let sourceDescription = context.captureSources
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
            .map(\.rawValue)
            .sorted()
            .joined(separator: ", ")

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
