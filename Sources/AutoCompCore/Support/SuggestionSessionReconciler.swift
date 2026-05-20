import Foundation

public enum SuggestionSessionReconciliationResult: Equatable, Sendable {
    case settled
    case pendingEcho
    case trailingWhitespace
    case typedThrough(session: ActiveSuggestionSession, typedText: String)
    case diverged
    case targetChanged
    case exhausted
}

public struct SuggestionSessionReconciler: Sendable {
    public var acceptanceEchoGraceInterval: TimeInterval

    public init(acceptanceEchoGraceInterval: TimeInterval = 3.0) {
        self.acceptanceEchoGraceInterval = acceptanceEchoGraceInterval
    }

    public func reconcile(
        context: TextContext,
        session: ActiveSuggestionSession,
        now: Date = Date(),
        targetMatches: Bool? = nil
    ) -> SuggestionSessionReconciliationResult {
        guard context.app == session.target.app,
              context.domain == session.target.domain,
              (targetMatches ?? (context.focusedElementID == session.target.focusedElementID)) else {
            return .targetChanged
        }

        if let selectedRange = context.selectedRange,
           selectedRange.length > 0 {
            return .diverged
        }

        if session.isExhausted,
           Self.textMatchesExpectedOrOnlyAddsTrailingWhitespace(
            context.textBeforeCursor,
            expectedText: session.expectedTextBeforeCursor
           ) {
            return .exhausted
        }

        if let typedThrough = typedThroughSession(
            observedText: context.textBeforeCursor,
            session: session,
            now: now
        ) {
            return typedThrough
        }

        return relation(
            observedText: context.textBeforeCursor,
            session: session,
            now: now
        )
    }

    private func typedThroughSession(
        observedText: String,
        session: ActiveSuggestionSession,
        now: Date
    ) -> SuggestionSessionReconciliationResult? {
        guard observedText.hasPrefix(session.expectedTextBeforeCursor) else {
            return nil
        }

        let typedText = String(observedText.dropFirst(session.expectedTextBeforeCursor.count))
        guard let updatedSession = session.advancingTypedText(typedText, at: now) else {
            return nil
        }

        return .typedThrough(session: updatedSession, typedText: typedText)
    }

    private func relation(
        observedText: String,
        session: ActiveSuggestionSession,
        now: Date
    ) -> SuggestionSessionReconciliationResult {
        if let relation = exactRelation(
            observedText: observedText,
            expectedText: session.expectedTextBeforeCursor,
            baseText: session.baseTextBeforeCursor,
            lastAcceptedAt: session.lastAcceptedAt,
            now: now
        ) {
            return relation
        }

        let normalizedObservedText = Self.normalizedWhitespace(in: observedText)
        let normalizedExpectedText = Self.normalizedWhitespace(in: session.expectedTextBeforeCursor)
        let normalizedBaseText = Self.normalizedWhitespace(in: session.baseTextBeforeCursor)
        if normalizedObservedText != observedText
            || normalizedExpectedText != session.expectedTextBeforeCursor
            || normalizedBaseText != session.baseTextBeforeCursor,
           let relation = exactRelation(
            observedText: normalizedObservedText,
            expectedText: normalizedExpectedText,
            baseText: normalizedBaseText,
            lastAcceptedAt: session.lastAcceptedAt,
            now: now
           ) {
            return relation
        }

        return .diverged
    }

    private func exactRelation(
        observedText: String,
        expectedText: String,
        baseText: String,
        lastAcceptedAt: Date,
        now: Date
    ) -> SuggestionSessionReconciliationResult? {
        if observedText == expectedText {
            return .settled
        }

        if Self.textMatchesExpectedOrOnlyAddsTrailingWhitespace(observedText, expectedText: expectedText) {
            return .trailingWhitespace
        }

        let isPotentialDelayedEcho = expectedText.hasPrefix(observedText)
            && observedText.hasPrefix(baseText)
        if isPotentialDelayedEcho,
           now.timeIntervalSince(lastAcceptedAt) <= acceptanceEchoGraceInterval {
            return .pendingEcho
        }

        return nil
    }

    public static func textMatchesExpectedOrOnlyAddsTrailingWhitespace(
        _ observedText: String,
        expectedText: String
    ) -> Bool {
        if observedText == expectedText {
            return true
        }

        guard observedText.hasPrefix(expectedText) else {
            return false
        }

        let suffix = observedText.dropFirst(expectedText.count)
        return suffix.unicodeScalars.allSatisfy {
            CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }

    public static func normalizedWhitespace(in text: String) -> String {
        var result = String.UnicodeScalarView()
        var previousWasWhitespace = false

        for scalar in text.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                if !previousWasWhitespace {
                    result.append(" ")
                    previousWasWhitespace = true
                }
            } else {
                result.append(scalar)
                previousWasWhitespace = false
            }
        }

        return String(result)
    }
}
