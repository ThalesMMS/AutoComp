import Foundation

public enum SuggestionTextNormalizer {
    public static func normalize(
        rawText: String,
        precedingText: String,
        trailingText: String? = nil,
        promptEchoCandidates: [String] = []
    ) -> String {
        var text = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")

        text = removeLeadingTemplateMarkers(from: text)
        text = removeLeadingPromptEchoes(
            from: text,
            precedingText: precedingText,
            promptEchoCandidates: promptEchoCandidates
        )
        text = firstUsefulLine(in: text)
        text = removeLeadingTemplateMarkers(from: text)
        text = removeLeadingPromptEchoes(
            from: text,
            precedingText: precedingText,
            promptEchoCandidates: promptEchoCandidates
        )

        if endsWithWhitespace(precedingText) {
            text = droppingLeadingWhitespace(from: text)
        }

        text = removeTrailingTextEcho(from: text, trailingText: trailingText)
        return trimmingTrailingWhitespaceAndNewlines(from: text)
    }

    private static func removeLeadingTemplateMarkers(from text: String) -> String {
        var remaining = text
        var didRemoveMarker = true

        while didRemoveMarker {
            didRemoveMarker = false
            let candidate = droppingLeadingWhitespaceAndNewlines(from: remaining)

            for marker in leadingMarkers {
                if candidate.hasPrefix(marker) {
                    remaining = candidate
                    remaining.removeFirst(marker.count)
                    didRemoveMarker = true
                    break
                }
            }

            for prefix in leadingLabelPrefixes {
                guard !didRemoveMarker,
                      candidate.lowercased().hasPrefix(prefix.lowercased()) else {
                    continue
                }

                remaining = candidate
                remaining.removeFirst(prefix.count)
                didRemoveMarker = true
                break
            }
        }

        return remaining
    }

    private static func removeLeadingPromptEchoes(
        from text: String,
        precedingText: String,
        promptEchoCandidates: [String]
    ) -> String {
        var remaining = text
        let candidates = ([precedingText] + promptEchoCandidates)
            .map { $0.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n") }
            .filter { !$0.isEmpty }
            .sorted { $0.count > $1.count }

        var didRemoveEcho = true
        while didRemoveEcho {
            didRemoveEcho = false
            remaining = droppingLeadingNewlines(from: remaining)

            for candidate in candidates where remaining.hasPrefix(candidate) {
                remaining.removeFirst(candidate.count)
                didRemoveEcho = true
                break
            }

            if didRemoveEcho {
                remaining = removeLeadingTemplateMarkers(from: remaining)
            }
        }

        return remaining
    }

    private static func firstUsefulLine(in text: String) -> String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let candidate = String(line)
            if candidate.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                continue
            }
            return candidate
        }

        return ""
    }

    private static func removeTrailingTextEcho(from text: String, trailingText: String?) -> String {
        guard let trailingText,
              !trailingText.isEmpty else {
            return text
        }

        let normalizedTrailingText = trailingText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        guard !normalizedTrailingText.isEmpty else {
            return text
        }

        if text == normalizedTrailingText {
            return ""
        }

        if text.hasPrefix(normalizedTrailingText) {
            return String(text.dropFirst(normalizedTrailingText.count))
        }

        if text.hasSuffix(normalizedTrailingText) {
            return String(text.dropLast(normalizedTrailingText.count))
        }

        return text
    }

    private static func endsWithWhitespace(_ text: String) -> Bool {
        text.unicodeScalars.last.map(CharacterSet.whitespacesAndNewlines.contains) == true
    }

    private static func droppingLeadingWhitespace(from text: String) -> String {
        String(text.unicodeScalars.drop { CharacterSet.whitespaces.contains($0) })
    }

    private static func droppingLeadingNewlines(from text: String) -> String {
        String(text.unicodeScalars.drop { CharacterSet.newlines.contains($0) })
    }

    private static func droppingLeadingWhitespaceAndNewlines(from text: String) -> String {
        String(text.unicodeScalars.drop { CharacterSet.whitespacesAndNewlines.contains($0) })
    }

    private static func trimmingTrailingWhitespaceAndNewlines(from text: String) -> String {
        var scalars = text.unicodeScalars
        while let last = scalars.last,
              CharacterSet.whitespacesAndNewlines.contains(last) {
            scalars.removeLast()
        }
        return String(scalars)
    }

    private static let leadingMarkers = [
        "<|assistant|>",
        "<|assistant",
        "<|im_start|>assistant",
        "<|im_end|>",
        "<|endoftext|>",
        "[/INST]",
        "<s>",
        "</s>"
    ]

    private static let leadingLabelPrefixes = [
        "Completion:",
        "Assistant:",
        "Response:"
    ]
}
