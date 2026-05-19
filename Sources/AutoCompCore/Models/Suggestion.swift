import Foundation

public struct Suggestion: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let baseContextID: UUID
    public var visibleText: String
    public var remainingText: String
    public var acceptedPrefix: String
    public let createdAt: Date
    public let latencyMs: Int

    public init(
        id: UUID = UUID(),
        baseContextID: UUID,
        visibleText: String,
        remainingText: String? = nil,
        acceptedPrefix: String = "",
        createdAt: Date = Date(),
        latencyMs: Int
    ) {
        self.id = id
        self.baseContextID = baseContextID
        self.visibleText = visibleText
        self.remainingText = remainingText ?? visibleText
        self.acceptedPrefix = acceptedPrefix
        self.createdAt = createdAt
        self.latencyMs = latencyMs
    }

    public var isExhausted: Bool {
        remainingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public mutating func acceptNextWord() -> String? {
        guard let token = SuggestionTextTokenizer.nextWordToken(in: remainingText) else {
            return nil
        }

        remainingText.removeFirst(token.count)
        let acceptedToken = SuggestionTextTokenizer.tokenForInsertion(token, beforeRemainingText: remainingText)
        acceptedPrefix += acceptedToken
        visibleText = remainingText
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
        return token
    }
}
