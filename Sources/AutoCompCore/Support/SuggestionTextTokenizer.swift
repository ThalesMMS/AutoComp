import Foundation

public enum SuggestionTextTokenizer {
    public static func nextWordToken(in text: String) -> String? {
        guard !text.isEmpty else {
            return nil
        }

        var token = ""
        var hasNonWhitespace = false

        for scalar in text.unicodeScalars {
            let character = Character(scalar)
            token.append(character)

            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if hasNonWhitespace {
                    break
                }
            } else {
                hasNonWhitespace = true
            }
        }

        return hasNonWhitespace ? token : nil
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
