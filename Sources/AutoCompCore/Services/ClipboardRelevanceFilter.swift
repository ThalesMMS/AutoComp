import Foundation

public struct ClipboardRelevanceDecision: Equatable, Sendable {
    public let isRelevant: Bool
    public let overlappingTokens: Set<String>

    public init(isRelevant: Bool, overlappingTokens: Set<String>) {
        self.isRelevant = isRelevant
        self.overlappingTokens = overlappingTokens
    }
}

public struct ClipboardRelevanceFilter: Sendable {
    public var minimumTokenLength: Int

    public init(minimumTokenLength: Int = 3) {
        self.minimumTokenLength = max(1, minimumTokenLength)
    }

    public func evaluate(clipboardText: String, textBeforeCursor: String) -> ClipboardRelevanceDecision {
        let contextTokens = tokens(in: textBeforeCursor)
        let clipboardTokens = tokens(in: clipboardText)
        let overlap = contextTokens.intersection(clipboardTokens)

        return ClipboardRelevanceDecision(
            isRelevant: !overlap.isEmpty,
            overlappingTokens: overlap
        )
    }

    public func tokens(in text: String) -> Set<String> {
        let words = text.lowercased().split { character in
            !character.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) }
        }
        return Set(words.map(String.init).filter { $0.count >= minimumTokenLength })
    }
}
