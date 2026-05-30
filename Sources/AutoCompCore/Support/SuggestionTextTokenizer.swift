import Foundation

public enum SuggestionTextTokenizer {
    /// Returns the next "word-like" token to accept from a suggestion.
    ///
    /// Behavior:
    /// - Preserves leading whitespace/newlines (if any) so that accepting "next word" can
    ///   advance across whitespace runs.
    /// - Treats whitespace as the primary delimiter once we've consumed any non-whitespace.
    /// - Includes contiguous punctuation that directly follows the word (e.g. "world!") and
    ///   the next whitespace delimiter when present.
    /// - If the text contains only whitespace, returns nil.
    public static func nextWordToken(in text: String) -> String? {
        guard !text.isEmpty else {
            return nil
        }

        var prefixScalars: [Unicode.Scalar] = []
        var tokenScalars: [Unicode.Scalar] = []
        var hasNonWhitespace = false

        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if hasNonWhitespace {
                    break
                }
                prefixScalars.append(scalar)
                continue
            }

            hasNonWhitespace = true
            tokenScalars.append(scalar)
        }

        guard hasNonWhitespace else {
            return nil
        }

        // Expand the token to include immediate trailing punctuation and one whitespace delimiter.
        // Example: "hello, world" -> token "hello, ".
        var remainder = text.unicodeScalars.dropFirst(prefixScalars.count + tokenScalars.count)
        while let next = remainder.first {
            if CharacterSet.whitespacesAndNewlines.contains(next) {
                tokenScalars.append(next)
                break
            }

            if CharacterSet.alphanumerics.contains(next) {
                break
            }

            tokenScalars.append(next)
            remainder = remainder.dropFirst()
        }

        return String(String.UnicodeScalarView(prefixScalars + tokenScalars))
    }

    public static func tokenForInsertion(_ token: String, beforeRemainingText remainingText: String) -> String {
        guard shouldAppendSpaceAfterAcceptedToken(token, beforeRemainingText: remainingText) else {
            return token
        }

        return token + " "
    }

    private static func shouldAppendSpaceAfterAcceptedToken(_ token: String, beforeRemainingText remainingText: String) -> Bool {
        if token.unicodeScalars.last.map(CharacterSet.whitespacesAndNewlines.contains) == true {
            return false
        }

        if remainingText.unicodeScalars.first.map(CharacterSet.whitespacesAndNewlines.contains) == true {
            return false
        }

        guard let lastMeaningfulScalar = lastMeaningfulScalar(in: token) else {
            return false
        }

        return punctuationThatNeedsFollowingSpace.contains(lastMeaningfulScalar)
    }

    private static let punctuationThatNeedsFollowingSpace = CharacterSet(charactersIn: ".,;:!?。！？；，：")

    private static let closingScalars = CharacterSet(charactersIn: "\"'”’)]}»")

    private static func lastMeaningfulScalar(in text: String) -> Unicode.Scalar? {
        for scalar in text.unicodeScalars.reversed() {
            if closingScalars.contains(scalar) || CharacterSet.whitespacesAndNewlines.contains(scalar) {
                continue
            }
            return scalar
        }
        return nil
    }
}
