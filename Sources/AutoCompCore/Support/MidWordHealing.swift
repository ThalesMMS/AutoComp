import Foundation

public enum MidWordRegenerationSuppression: String, Equatable, Sendable {
    case notInsideWord = "not-inside-word"
    case numericStem = "numeric-stem"
    case riskyIdentifier = "risky-identifier"
    case stemTooLong = "stem-too-long"
}

public struct MidWordRegenerationPlan: Equatable, Sendable {
    public let head: String
    public let requiredPrefix: String
    public let visibleStem: String
    public let suffix: String

    public init(head: String, requiredPrefix: String, visibleStem: String, suffix: String) {
        self.head = head
        self.requiredPrefix = requiredPrefix
        self.visibleStem = visibleStem
        self.suffix = suffix
    }
}

public enum MidWordRegenerationDecision: Equatable, Sendable {
    case plan(MidWordRegenerationPlan)
    case suppress(MidWordRegenerationSuppression)
}

public struct MidWordRegenerationPlanner: Sendable {
    public let maximumStemCharacters: Int

    public init(maximumStemCharacters: Int = 32) {
        self.maximumStemCharacters = max(4, maximumStemCharacters)
    }

    public func decision(textBeforeCursor: String, textAfterCursor: String?) -> MidWordRegenerationDecision {
        guard let suffix = textAfterCursor, let firstAfter = suffix.first,
              let lastBefore = textBeforeCursor.last,
              isLexical(lastBefore), isLexical(firstAfter) else {
            return .suppress(.notInsideWord)
        }

        var boundary = textBeforeCursor.endIndex
        while boundary > textBeforeCursor.startIndex {
            let previous = textBeforeCursor.index(before: boundary)
            guard isLexical(textBeforeCursor[previous]) else { break }
            boundary = previous
        }
        let stem = String(textBeforeCursor[boundary...])
        guard stem.count <= maximumStemCharacters else { return .suppress(.stemTooLong) }
        guard !stem.allSatisfy(\.isNumber) else { return .suppress(.numericStem) }
        guard stem.allSatisfy({ $0.isLetter || $0.unicodeScalars.allSatisfy(\.properties.isJoinControl) }) else {
            return .suppress(.riskyIdentifier)
        }
        return .plan(MidWordRegenerationPlan(
            head: String(textBeforeCursor[..<boundary]),
            requiredPrefix: stem,
            visibleStem: stem,
            suffix: suffix
        ))
    }

    private func isLexical(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
            || character.unicodeScalars.allSatisfy { CharacterSet.nonBaseCharacters.contains($0) }
    }
}

public enum SuffixOverlapDecision: Equatable, Sendable {
    case keep(String)
    case truncated(String, overlapCharacters: Int)
    case suppress
}

public struct SuffixOverlapTruncator: Sendable {
    public init() {}

    public func truncate(candidate: String, suffix: String) -> SuffixOverlapDecision {
        let candidateCharacters = Array(candidate)
        let suffixCharacters = Array(suffix)
        guard !candidateCharacters.isEmpty, !suffixCharacters.isEmpty else { return .keep(candidate) }
        if candidateCharacters == suffixCharacters || suffixCharacters.starts(with: candidateCharacters) {
            return .suppress
        }

        if let fullStart = fullSuffixStart(candidate: candidateCharacters, suffix: suffixCharacters) {
            guard fullStart > 0, isSafeCut(candidateCharacters, at: fullStart) else { return .suppress }
            return trimmed(candidateCharacters, end: fullStart, overlap: suffixCharacters.count)
        }

        let maximum = min(candidateCharacters.count, suffixCharacters.count)
        for length in stride(from: maximum, through: 1, by: -1) {
            guard Array(candidateCharacters.suffix(length)) == Array(suffixCharacters.prefix(length)) else { continue }
            let cut = candidateCharacters.count - length
            guard cut > 0, isSafeCut(candidateCharacters, at: cut) else { return .suppress }
            return trimmed(candidateCharacters, end: cut, overlap: length)
        }
        return .keep(candidate)
    }

    private func fullSuffixStart(candidate: [Character], suffix: [Character]) -> Int? {
        guard candidate.count >= suffix.count else { return nil }
        for start in 0...(candidate.count - suffix.count)
            where Array(candidate[start..<(start + suffix.count)]) == suffix {
            return start
        }
        return nil
    }

    private func isSafeCut(_ characters: [Character], at index: Int) -> Bool {
        guard index > 0, index <= characters.count else { return false }
        let previous = characters[index - 1]
        let nextIsBoundary = index < characters.count
            && (characters[index].isWhitespace || characters[index].isPunctuation)
        return previous.isWhitespace || previous.isPunctuation || nextIsBoundary
    }

    private func trimmed(_ characters: [Character], end: Int, overlap: Int) -> SuffixOverlapDecision {
        let useful = String(characters[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
        return useful.isEmpty ? .suppress : .truncated(useful, overlapCharacters: overlap)
    }
}

public enum CompletionSeamRejection: String, Equatable, Sendable {
    case empty
    case duplicatedSpace = "duplicated-space"
    case invalidAlphaNumericJoin = "invalid-alphanumeric-join"
    case repeatedPunctuation = "repeated-punctuation"
    case incompatibleScript = "incompatible-script"
}

public enum CompletionSeamDecision: Equatable, Sendable {
    case allow
    case reject(CompletionSeamRejection)
}

public struct CompletionSeamValidator: Sendable {
    public init() {}

    public func validate(candidate: String, before: String, after: String?) -> CompletionSeamDecision {
        guard !candidate.isEmpty else { return .reject(.empty) }
        if before.last?.isWhitespace == true && candidate.first?.isWhitespace == true {
            return .reject(.duplicatedSpace)
        }
        if candidate.last?.isWhitespace == true && after?.first?.isWhitespace == true {
            return .reject(.duplicatedSpace)
        }
        if let left = candidate.last, let right = after?.first,
           (left.isLetter || left.isNumber), (right.isLetter || right.isNumber) {
            return .reject(.invalidAlphaNumericJoin)
        }
        if let left = candidate.last, let right = after?.first,
           left.isPunctuation, right.isPunctuation, left == right {
            return .reject(.repeatedPunctuation)
        }
        if let candidateScript = scriptFamily(candidate),
           let surroundingScript = scriptFamily(before + (after ?? "")),
           candidateScript != surroundingScript {
            return .reject(.incompatibleScript)
        }
        return .allow
    }

    private func scriptFamily(_ text: String) -> Int? {
        for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
            switch scalar.value {
            case 0x0041...0x024F: return 1
            case 0x0400...0x052F: return 2
            case 0x0600...0x06FF: return 3
            case 0x3040...0x30FF, 0x3400...0x9FFF: return 4
            default: return 5
            }
        }
        return nil
    }
}

public enum MidWordCandidateReconciliationDecision: Equatable, Sendable {
    case publish(String)
    case suppress
}

public struct MidWordCandidateReconciler: Sendable {
    public init() {}

    public func reconcile(candidate: String, plan: MidWordRegenerationPlan) -> MidWordCandidateReconciliationDecision {
        guard candidate.hasPrefix(plan.requiredPrefix) else { return .suppress }
        let withoutVisibleStem = String(candidate.dropFirst(plan.visibleStem.count))
        guard !withoutVisibleStem.isEmpty else { return .suppress }
        switch SuffixOverlapTruncator().truncate(candidate: withoutVisibleStem, suffix: plan.suffix) {
        case .suppress:
            return .suppress
        case .keep(let value), .truncated(let value, _):
            return value.isEmpty ? .suppress : .publish(value)
        }
    }
}

public struct SuffixCompatibilityCandidate: Equatable, Sendable {
    public let index: Int
    public let baseScore: Double
    public let suffixLogProbability: Double?

    public init(index: Int, baseScore: Double, suffixLogProbability: Double?) {
        self.index = index
        self.baseScore = baseScore
        self.suffixLogProbability = suffixLogProbability
    }
}

public struct LocalSuffixCompatibilityReranker: Sendable {
    public struct Configuration: Equatable, Sendable {
        public var enabled: Bool
        public var weight: Double
        public var maximumCandidates: Int

        public init(enabled: Bool = false, weight: Double = 0.15, maximumCandidates: Int = 3) {
            self.enabled = enabled
            self.weight = min(max(weight, 0), 0.5)
            self.maximumCandidates = min(max(maximumCandidates, 1), 5)
        }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    public func ranked(_ candidates: [SuffixCompatibilityCandidate]) -> [SuffixCompatibilityCandidate] {
        guard configuration.enabled,
              candidates.prefix(configuration.maximumCandidates).allSatisfy({ $0.suffixLogProbability != nil }) else {
            return candidates
        }
        let rerankable = Array(candidates.prefix(configuration.maximumCandidates)).sorted {
            let lhs = $0.baseScore + configuration.weight * ($0.suffixLogProbability ?? 0)
            let rhs = $1.baseScore + configuration.weight * ($1.suffixLogProbability ?? 0)
            return lhs == rhs ? $0.index < $1.index : lhs > rhs
        }
        return rerankable + candidates.dropFirst(configuration.maximumCandidates)
    }
}
