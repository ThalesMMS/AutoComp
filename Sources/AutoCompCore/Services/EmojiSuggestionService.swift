import Foundation

public struct EmojiSuggestion: Identifiable, Equatable, Sendable {
    public var id: String { shortcode }
    public let emoji: String
    public let shortcode: String
}

public struct EmojiSuggestionService: Sendable {
    public static let defaultEmoji: [EmojiSuggestion] = [
        EmojiSuggestion(emoji: "😀", shortcode: "grinning"),
        EmojiSuggestion(emoji: "😂", shortcode: "joy"),
        EmojiSuggestion(emoji: "🙂", shortcode: "slight_smile"),
        EmojiSuggestion(emoji: "😍", shortcode: "heart_eyes"),
        EmojiSuggestion(emoji: "🙏", shortcode: "pray"),
        EmojiSuggestion(emoji: "👍", shortcode: "thumbsup"),
        EmojiSuggestion(emoji: "🎉", shortcode: "tada"),
        EmojiSuggestion(emoji: "✅", shortcode: "white_check_mark"),
        EmojiSuggestion(emoji: "🔥", shortcode: "fire"),
        EmojiSuggestion(emoji: "🚀", shortcode: "rocket")
    ]

    private let emoji: [EmojiSuggestion]

    public init(emoji: [EmojiSuggestion] = EmojiSuggestionService.defaultEmoji) {
        self.emoji = emoji
    }

    public func suggestion(for textBeforeCursor: String, contextID: UUID) -> Suggestion? {
        guard let colon = textBeforeCursor.lastIndex(of: ":") else {
            return nil
        }

        let fragment = String(textBeforeCursor[textBeforeCursor.index(after: colon)...])
        guard !fragment.contains(where: { $0.isWhitespace || $0.isPunctuation && $0 != "_" }) else {
            return nil
        }

        let match = emoji.first { candidate in
            candidate.shortcode.localizedCaseInsensitiveContains(fragment)
        }

        guard let match else {
            return nil
        }

        return Suggestion(baseContextID: contextID, visibleText: match.emoji, latencyMs: 0)
    }
}
