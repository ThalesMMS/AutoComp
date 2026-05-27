import Foundation

public struct ClipboardContentDistiller: Sendable {
    public var maxLines: Int
    public var maxCharacters: Int

    public init(maxLines: Int = 6, maxCharacters: Int = 700) {
        self.maxLines = max(1, maxLines)
        self.maxCharacters = max(80, maxCharacters)
    }

    public func distill(_ text: String, matchingTokens: Set<String>) -> String {
        let normalizedLines = text
            .components(separatedBy: .newlines)
            .map(normalizedLine)
            .filter { !$0.isEmpty }

        guard !normalizedLines.isEmpty else {
            return ""
        }

        let candidateLines: [String]
        if normalizedLines.count <= maxLines && text.count <= maxCharacters {
            candidateLines = normalizedLines
        } else {
            let relevantLines = normalizedLines.filter { line in
                let lowercasedLine = line.lowercased()
                return matchingTokens.contains { lowercasedLine.contains($0) }
            }
            candidateLines = relevantLines.isEmpty ? Array(normalizedLines.prefix(maxLines)) : relevantLines
        }

        return limitedSummary(from: candidateLines)
    }

    private func normalizedLine(_ line: String) -> String {
        line
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func limitedSummary(from lines: [String]) -> String {
        var summary = ""
        var emittedLines = 0

        for line in lines where emittedLines < maxLines {
            let separator = summary.isEmpty ? "" : "\n"
            let candidate = summary + separator + line
            if candidate.count > maxCharacters {
                let remaining = maxCharacters - summary.count - separator.count
                if remaining > 0 {
                    summary += separator + String(line.prefix(remaining))
                }
                break
            }
            summary = candidate
            emittedLines += 1
        }

        return summary.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
