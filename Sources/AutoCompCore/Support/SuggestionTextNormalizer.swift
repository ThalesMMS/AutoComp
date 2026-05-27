import Foundation

public enum SuggestionTextNormalizer {
    public static func normalize(
        rawText: String,
        request: CompletionRequest
    ) -> String {
        normalize(
            rawText: rawText,
            precedingText: request.truncatedTextBeforeCursor,
            trailingText: request.truncatedTextAfterCursor,
            promptEchoCandidates: request.promptEchoCandidates
        )
    }

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
        text = removeMarkdownWrappers(from: text)
        text = removeLeadingPromptEchoes(
            from: text,
            precedingText: precedingText,
            promptEchoCandidates: promptEchoCandidates
        )
        text = removeLeadingExplanatoryPreamble(from: text)
        text = firstUsefulLine(in: text)
        text = removeMarkdownWrappers(from: text)
        text = removeLeadingTemplateMarkers(from: text)
        text = removeLeadingPromptEchoes(
            from: text,
            precedingText: precedingText,
            promptEchoCandidates: promptEchoCandidates
        )
        text = removeLeadingExplanatoryPreamble(from: text)

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

    private static func removeMarkdownWrappers(from text: String) -> String {
        var remaining = text
        remaining = removeLeadingCodeFence(from: remaining)
        remaining = removeTrailingCodeFence(from: remaining)
        remaining = removeInlineMarkdownWrapper(from: remaining)
        return remaining
    }

    private static func removeLeadingCodeFence(from text: String) -> String {
        let candidate = droppingLeadingWhitespaceAndNewlines(from: text)
        guard hasCodeFencePrefix(candidate) else {
            return text
        }

        guard let lineEnd = candidate.firstIndex(of: "\n") else {
            return removeInlineMarkdownWrapper(from: candidate)
        }

        return String(candidate[candidate.index(after: lineEnd)...])
    }

    private static func removeTrailingCodeFence(from text: String) -> String {
        let withoutTrailingWhitespace = trimmingTrailingWhitespaceAndNewlines(from: text)
        let lines = withoutTrailingWhitespace.split(separator: "\n", omittingEmptySubsequences: false)
        guard let last = lines.last,
              isCodeFenceLine(String(last)) else {
            return text
        }

        return lines.dropLast().joined(separator: "\n")
    }

    private static func removeInlineMarkdownWrapper(from text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for wrapper in inlineMarkdownWrappers
            where trimmed.hasPrefix(wrapper)
                && trimmed.hasSuffix(wrapper)
                && trimmed.count >= wrapper.count * 2 {
            return String(trimmed.dropFirst(wrapper.count).dropLast(wrapper.count))
        }
        return text
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

    private static func removeLeadingExplanatoryPreamble(from text: String) -> String {
        let candidate = droppingLeadingWhitespaceAndNewlines(from: text)
        let lowercased = candidate.lowercased()
        for prefix in leadingExplanationPrefixes where lowercased.hasPrefix(prefix) {
            return String(candidate.dropFirst(prefix.count))
        }
        return text
    }

    private static func firstUsefulLine(in text: String) -> String {
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let candidate = String(line)
            let trimmed = candidate.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || isCodeFenceLine(trimmed) || isExplanatoryPreambleLine(trimmed) {
                continue
            }
            return candidate
        }

        return ""
    }

    private static func hasCodeFencePrefix(_ text: String) -> Bool {
        codeFencePrefixes.contains { text.hasPrefix($0) }
    }

    private static func isCodeFenceLine(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        return codeFencePrefixes.contains { trimmed.hasPrefix($0) }
    }

    private static func isExplanatoryPreambleLine(_ text: String) -> Bool {
        let lowercased = text.lowercased()
        return leadingExplanationPrefixes.contains { lowercased == $0 || lowercased == String($0.dropLast()) }
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
        "<|fim_prefix|>",
        "<|fim_suffix|>",
        "<|fim_middle|>",
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

    private static let codeFencePrefixes = [
        "```",
        "~~~"
    ]

    private static let inlineMarkdownWrappers = [
        "```",
        "~~~",
        "`"
    ]

    private static let leadingExplanationPrefixes = [
        "sure, here's the completion:",
        "sure, here is the completion:",
        "here's the completion:",
        "here is the completion:",
        "the completion is:",
        "the completed text is:",
        "you can write:"
    ]
}
