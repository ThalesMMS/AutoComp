import Foundation

public struct ActiveSuggestionTarget: Equatable, Sendable {
    public let app: AppIdentity
    public let domain: String?
    public let focusedElementID: String
    public let selectedRange: NSRange?
    public let selectedText: String?

    public init(
        app: AppIdentity,
        domain: String?,
        focusedElementID: String,
        selectedRange: NSRange?,
        selectedText: String? = nil
    ) {
        self.app = app
        self.domain = domain
        self.focusedElementID = focusedElementID
        self.selectedRange = selectedRange
        self.selectedText = selectedText
    }

    public init(context: TextContext) {
        self.init(
            app: context.app,
            domain: context.domain,
            focusedElementID: context.focusedElementID,
            selectedRange: context.selectedRange,
            selectedText: context.selectedText
        )
    }
}

public struct ActiveSuggestionSession: Equatable, Sendable {
    public let target: ActiveSuggestionTarget
    public let baseTextBeforeCursor: String
    public let fullText: String
    public let acceptedText: String
    public let remainingText: String
    public let latencyMs: Int
    public let lastAcceptedAt: Date

    public init(
        target: ActiveSuggestionTarget,
        baseTextBeforeCursor: String,
        fullText: String,
        acceptedText: String,
        remainingText: String,
        latencyMs: Int,
        lastAcceptedAt: Date
    ) {
        self.target = target
        self.baseTextBeforeCursor = baseTextBeforeCursor
        self.fullText = fullText
        self.acceptedText = acceptedText
        self.remainingText = remainingText
        self.latencyMs = latencyMs
        self.lastAcceptedAt = lastAcceptedAt
    }

    public init(
        baseContext: TextContext,
        fullText: String,
        acceptedText: String,
        remainingText: String,
        latencyMs: Int,
        lastAcceptedAt: Date
    ) {
        self.init(
            target: ActiveSuggestionTarget(context: baseContext),
            baseTextBeforeCursor: baseContext.textBeforeCursor,
            fullText: fullText,
            acceptedText: acceptedText,
            remainingText: remainingText,
            latencyMs: latencyMs,
            lastAcceptedAt: lastAcceptedAt
        )
    }

    public var consumedCharacterCount: Int {
        acceptedText.count
    }

    public var expectedTextBeforeCursor: String {
        baseTextBeforeCursor + acceptedText
    }

    public var isExhausted: Bool {
        remainingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    public func advancingTypedText(_ typedText: String, at date: Date) -> ActiveSuggestionSession? {
        guard !typedText.isEmpty,
              remainingText.hasPrefix(typedText) else {
            return nil
        }

        return ActiveSuggestionSession(
            target: target,
            baseTextBeforeCursor: baseTextBeforeCursor,
            fullText: fullText,
            acceptedText: acceptedText + typedText,
            remainingText: String(remainingText.dropFirst(typedText.count)),
            latencyMs: latencyMs,
            lastAcceptedAt: date
        )
    }
}
