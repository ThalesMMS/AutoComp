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
    public var anchorReconciler: SuggestionAnchorReconciler

    public init(
        acceptanceEchoGraceInterval: TimeInterval = 3.0,
        anchorReconciler: SuggestionAnchorReconciler = SuggestionAnchorReconciler()
    ) {
        self.acceptanceEchoGraceInterval = acceptanceEchoGraceInterval
        self.anchorReconciler = anchorReconciler
    }

    public func reconcile(
        context: TextContext,
        session: ActiveSuggestionSession,
        now: Date = Date(),
        targetMatches: Bool? = nil
    ) -> SuggestionSessionReconciliationResult {
        let anchor = session.anchor
        let anchorResult = anchorReconciler.reconcile(
            context: context,
            anchor: anchor,
            targetMatches: targetMatches
        )

        switch anchorResult {
        case .exhausted:
            if !session.isExhausted,
               let typedText = typedThroughText(
                observedText: context.textBeforeCursor,
                session: session
               ),
               let updatedSession = session.advancingTypedText(typedText, at: now) {
                return .typedThrough(session: updatedSession, typedText: typedText)
            }
            return .exhausted
        case .remaining(let remainingText):
            if remainingText == session.remainingText {
                return relation(
                    observedText: context.textBeforeCursor,
                    session: session,
                    now: now
                )
            }

            guard let typedText = session.typedText(toRemainingText: remainingText),
                  let updatedSession = session.advancingTypedText(typedText, at: now) else {
                return .diverged
            }
            return .typedThrough(session: updatedSession, typedText: typedText)
        case .diverged(let reason):
            switch reason {
            case .appChanged, .domainChanged, .focusedElementChanged, .stableFieldChanged:
                return .targetChanged
            case .selectionChanged, .suffixChanged:
                return .diverged
            case .baseTextChanged, .acceptedTextDeleted, .typedTextMismatch:
                return relation(
                    observedText: context.textBeforeCursor,
                    session: session,
                    now: now
                )
            }
        }
    }

    private func typedThroughText(
        observedText: String,
        session: ActiveSuggestionSession
    ) -> String? {
        guard observedText.hasPrefix(session.expectedTextBeforeCursor) else {
            return nil
        }

        let typedText = String(observedText.dropFirst(session.expectedTextBeforeCursor.count))
        guard !typedText.isEmpty,
              session.remainingText.hasPrefix(typedText) else {
            return nil
        }

        return typedText
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
        SuggestionAnchorReconciler.textMatchesExpectedOrOnlyAddsTrailingWhitespace(
            observedText,
            expectedText: expectedText
        )
    }

    public static func normalizedWhitespace(in text: String) -> String {
        SuggestionAnchorReconciler.normalizedWhitespace(in: text)
    }
}
