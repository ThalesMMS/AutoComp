import Foundation

public struct SuggestionAlternative: Codable, Equatable, Sendable {
    public var visibleText: String
    public var rawText: String?

    public init(visibleText: String, rawText: String? = nil) {
        self.visibleText = visibleText
        self.rawText = rawText
    }
}

public struct Suggestion: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let baseContextID: UUID

    /// Guardrail metadata for binding a suggestion to the context it was generated for.
    ///
    /// This is intentionally **not** `Codable`: suggestions may flow through Codable pipelines
    /// (e.g. diagnostics), but binding is in-memory only and should be cleared on hide/invalidate.
    public var binding: SuggestionBinding?

    public var visibleText: String
    public var remainingText: String
    public var acceptedPrefix: String
    public var rawText: String?
    public var alternatives: [SuggestionAlternative]
    public var selectedAlternativeIndex: Int
    public var completionRoute: CompletionRoute?
    public let createdAt: Date
    public let latencyMs: Int

    private enum CodingKeys: String, CodingKey {
        case id
        case baseContextID
        case visibleText
        case remainingText
        case acceptedPrefix
        case rawText
        case alternatives
        case selectedAlternativeIndex
        case completionRoute
        case createdAt
        case latencyMs
    }

    public init(
        id: UUID = UUID(),
        baseContextID: UUID,
        visibleText: String,
        remainingText: String? = nil,
        binding: SuggestionBinding? = nil,
        acceptedPrefix: String = "",
        rawText: String? = nil,
        alternatives: [SuggestionAlternative] = [],
        selectedAlternativeIndex: Int = 0,
        completionRoute: CompletionRoute? = nil,
        createdAt: Date = Date(),
        latencyMs: Int
    ) {
        let normalizedAlternatives = alternatives.isEmpty
            ? [SuggestionAlternative(visibleText: visibleText, rawText: rawText)]
            : alternatives
        let boundedIndex = min(max(0, selectedAlternativeIndex), max(0, normalizedAlternatives.count - 1))
        let selectedAlternative = normalizedAlternatives[boundedIndex]
        self.id = id
        self.baseContextID = baseContextID
        self.binding = binding
        self.visibleText = selectedAlternative.visibleText
        self.remainingText = remainingText ?? selectedAlternative.visibleText
        self.acceptedPrefix = acceptedPrefix
        self.rawText = selectedAlternative.rawText ?? rawText
        self.alternatives = normalizedAlternatives
        self.selectedAlternativeIndex = boundedIndex
        self.completionRoute = completionRoute
        self.createdAt = createdAt
        self.latencyMs = latencyMs
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(UUID.self, forKey: .id)
        let baseContextID = try container.decode(UUID.self, forKey: .baseContextID)
        let visibleText = try container.decode(String.self, forKey: .visibleText)
        let remainingText = try container.decode(String.self, forKey: .remainingText)
        let acceptedPrefix = try container.decode(String.self, forKey: .acceptedPrefix)
        let rawText = try container.decodeIfPresent(String.self, forKey: .rawText)
        let alternatives = try container.decodeIfPresent([SuggestionAlternative].self, forKey: .alternatives) ?? []
        let selectedAlternativeIndex = try container.decodeIfPresent(Int.self, forKey: .selectedAlternativeIndex) ?? 0
        let completionRoute = try container.decodeIfPresent(CompletionRoute.self, forKey: .completionRoute)
        let createdAt = try container.decode(Date.self, forKey: .createdAt)
        let latencyMs = try container.decode(Int.self, forKey: .latencyMs)

        self.init(
            id: id,
            baseContextID: baseContextID,
            visibleText: visibleText,
            remainingText: remainingText,
            binding: nil,
            acceptedPrefix: acceptedPrefix,
            rawText: rawText,
            alternatives: alternatives,
            selectedAlternativeIndex: selectedAlternativeIndex,
            completionRoute: completionRoute,
            createdAt: createdAt,
            latencyMs: latencyMs
        )
    }

    public var isExhausted: Bool {
        remainingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public var hasMultipleAlternatives: Bool {
        alternatives.count > 1
    }

    @discardableResult
    public mutating func selectAlternative(offset: Int) -> Bool {
        guard hasMultipleAlternatives else {
            return false
        }

        let count = alternatives.count
        let nextIndex = (selectedAlternativeIndex + offset % count + count) % count
        guard nextIndex != selectedAlternativeIndex else {
            return false
        }

        self = Suggestion(
            id: id,
            baseContextID: baseContextID,
            visibleText: alternatives[nextIndex].visibleText,
            binding: binding,
            rawText: alternatives[nextIndex].rawText ?? rawText,
            alternatives: alternatives,
            selectedAlternativeIndex: nextIndex,
            completionRoute: completionRoute,
            createdAt: createdAt,
            latencyMs: latencyMs
        )
        return true
    }

    public mutating func collapseAlternativesToCurrentText() {
        alternatives = [SuggestionAlternative(visibleText: remainingText, rawText: rawText)]
        selectedAlternativeIndex = 0
    }

    public mutating func acceptNextWord() -> String? {
        if hasMultipleAlternatives {
            return acceptAll()
        }

        guard let token = SuggestionTextTokenizer.nextWordToken(in: remainingText) else {
            return nil
        }

        remainingText.removeFirst(token.count)
        let acceptedToken = SuggestionTextTokenizer.tokenForInsertion(token, beforeRemainingText: remainingText)
        acceptedPrefix += acceptedToken
        visibleText = remainingText
        collapseAlternativesToCurrentText()
        return acceptedToken
    }

    public mutating func acceptAll() -> String? {
        guard !remainingText.isEmpty else {
            return nil
        }

        let token = remainingText
        acceptedPrefix += token
        remainingText = ""
        visibleText = ""
        collapseAlternativesToCurrentText()
        return token
    }
}
