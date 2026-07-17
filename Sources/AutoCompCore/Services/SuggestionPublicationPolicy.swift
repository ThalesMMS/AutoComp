import Foundation

public enum SuggestionPublicationPolicy {
    public enum Decision: Equatable, Sendable {
        case publish(Suggestion)
        case suppressEmpty
    }

    /// Applies the final, content-only normalization used immediately before a
    /// suggestion reaches a presenter. Keeping this policy in AutoCompCore lets
    /// headless evaluation exercise the same behavior as the app.
    public static func evaluate(_ suggestion: Suggestion, for context: TextContext) -> Decision {
        guard endsWithTriggerWhitespace(context.textBeforeCursor) else {
            return suggestion.visibleText.isEmpty ? .suppressEmpty : .publish(suggestion)
        }

        var normalized = suggestion
        normalized.visibleText = droppingLeadingWhitespaceAndNewlines(from: normalized.visibleText)
        normalized.remainingText = droppingLeadingWhitespaceAndNewlines(from: normalized.remainingText)
        return normalized.visibleText.isEmpty ? .suppressEmpty : .publish(normalized)
    }

    private static func endsWithTriggerWhitespace(_ text: String) -> Bool {
        text.unicodeScalars.last.map(CharacterSet.whitespacesAndNewlines.contains) == true
    }

    private static func droppingLeadingWhitespaceAndNewlines(from text: String) -> String {
        String(text.unicodeScalars.drop { CharacterSet.whitespacesAndNewlines.contains($0) })
    }
}
