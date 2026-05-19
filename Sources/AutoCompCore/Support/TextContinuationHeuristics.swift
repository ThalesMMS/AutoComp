import Foundation

public enum TextContinuationHeuristics {
    public static func shouldSuppressAutocomplete(after textBeforeCursor: String) -> Bool {
        let trimmed = textBeforeCursor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let lastMeaningfulScalar = lastMeaningfulScalar(in: trimmed) else {
            return false
        }

        return terminalSentenceScalars.contains(lastMeaningfulScalar)
    }

    private static let terminalSentenceScalars = CharacterSet(charactersIn: ".!?。！？")

    private static let closingScalars = CharacterSet(charactersIn: "\"'”’)]}»")

    private static func lastMeaningfulScalar(in text: String) -> Unicode.Scalar? {
        for scalar in text.unicodeScalars.reversed() {
            if closingScalars.contains(scalar) {
                continue
            }
            return scalar
        }
        return nil
    }
}
