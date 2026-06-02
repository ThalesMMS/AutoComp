import Foundation

public struct SuggestionAnchor: Equatable, Sendable {
    public let target: ActiveSuggestionTarget
    public let baseTextBeforeCursor: String
    public let fullText: String
    public let acceptedText: String
    public let remainingText: String

    public init(
        target: ActiveSuggestionTarget,
        baseTextBeforeCursor: String,
        fullText: String,
        acceptedText: String,
        remainingText: String
    ) {
        self.target = target
        self.baseTextBeforeCursor = baseTextBeforeCursor
        self.fullText = fullText
        self.acceptedText = acceptedText
        self.remainingText = remainingText
    }

    public init(
        context: TextContext,
        fullText: String,
        acceptedText: String,
        remainingText: String
    ) {
        self.init(
            target: ActiveSuggestionTarget(context: context),
            baseTextBeforeCursor: context.textBeforeCursor,
            fullText: fullText,
            acceptedText: acceptedText,
            remainingText: remainingText
        )
    }

    public init(context: TextContext, suggestion: Suggestion) {
        self.init(
            context: context,
            fullText: suggestion.acceptedPrefix + suggestion.remainingText,
            acceptedText: suggestion.acceptedPrefix,
            remainingText: suggestion.remainingText
        )
    }

    public init(session: ActiveSuggestionSession) {
        self.init(
            target: session.target,
            baseTextBeforeCursor: session.baseTextBeforeCursor,
            fullText: session.fullText,
            acceptedText: session.acceptedText,
            remainingText: session.remainingText
        )
    }

    public var expectedTextBeforeCursor: String {
        baseTextBeforeCursor + acceptedText
    }

    public var isExhausted: Bool {
        remainingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public enum SuggestionAnchorDivergenceReason: String, Equatable, Sendable {
    case appChanged = "app-changed"
    case domainChanged = "domain-changed"
    case stableFieldChanged = "stable-field-changed"
    case focusedElementChanged = "focused-element-changed"
    case selectionChanged = "selection-changed"
    case suffixChanged = "suffix-changed"
    case baseTextChanged = "base-text-changed"
    case acceptedTextDeleted = "accepted-text-deleted"
    case typedTextMismatch = "typed-text-mismatch"
}

public enum SuggestionAnchorReconciliation: Equatable, Sendable {
    case remaining(String)
    case exhausted
    case diverged(reason: SuggestionAnchorDivergenceReason)
}

public struct SuggestionAnchorReconciler: Sendable {
    public init() {}

    public func reconcile(
        context: TextContext,
        anchor: SuggestionAnchor,
        targetMatches: Bool? = nil
    ) -> SuggestionAnchorReconciliation {
        if let targetDivergence = targetDivergence(
            context: context,
            anchor: anchor,
            targetMatches: targetMatches
        ) {
            return .diverged(reason: targetDivergence)
        }

        if selectionDiverged(context: context, anchor: anchor) {
            return .diverged(reason: .selectionChanged)
        }

        if suffixDiverged(context: context, anchor: anchor) {
            return .diverged(reason: .suffixChanged)
        }

        return textReconciliation(context.textBeforeCursor, anchor: anchor)
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

    private func targetDivergence(
        context: TextContext,
        anchor: SuggestionAnchor,
        targetMatches: Bool?
    ) -> SuggestionAnchorDivergenceReason? {
        guard context.app == anchor.target.app else {
            return .appChanged
        }

        guard context.domain == anchor.target.domain else {
            return .domainChanged
        }

        if let targetMatches {
            return targetMatches ? nil : .focusedElementChanged
        }

        if let anchorStableField = anchor.target.stableFieldIdentity,
           let liveStableField = context.stableFieldIdentity {
            return anchorStableField.matchesStableTarget(liveStableField)
                ? nil
                : .stableFieldChanged
        }

        return context.focusedElementID == anchor.target.focusedElementID
            ? nil
            : .focusedElementChanged
    }

    private func selectionDiverged(context: TextContext, anchor: SuggestionAnchor) -> Bool {
        let hasActiveSelection = (context.selectedRange?.length ?? 0) > 0
            || context.selectedText?.isEmpty == false
        guard hasActiveSelection else {
            return false
        }

        return context.textBeforeCursor != anchor.baseTextBeforeCursor
            || context.selectedRange != anchor.target.selectedRange
            || context.selectedText != anchor.target.selectedText
    }

    private func suffixDiverged(context: TextContext, anchor: SuggestionAnchor) -> Bool {
        guard let anchorSuffix = anchor.target.textAfterCursor,
              let liveSuffix = context.textAfterCursor else {
            return false
        }

        return anchorSuffix != liveSuffix
    }

    private func textReconciliation(
        _ observedText: String,
        anchor: SuggestionAnchor
    ) -> SuggestionAnchorReconciliation {
        let expectedText = anchor.expectedTextBeforeCursor
        if observedText == expectedText {
            return anchor.isExhausted ? .exhausted : .remaining(anchor.remainingText)
        }

        if anchor.isExhausted,
           Self.textMatchesExpectedOrOnlyAddsTrailingWhitespace(observedText, expectedText: expectedText) {
            return .exhausted
        }

        guard observedText.hasPrefix(expectedText) else {
            if expectedText.hasPrefix(observedText),
               observedText.hasPrefix(anchor.baseTextBeforeCursor) {
                return .diverged(reason: .acceptedTextDeleted)
            }

            if !observedText.hasPrefix(anchor.baseTextBeforeCursor) {
                return .diverged(reason: .baseTextChanged)
            }

            return .diverged(reason: .typedTextMismatch)
        }

        let typedText = String(observedText.dropFirst(expectedText.count))
        guard !typedText.isEmpty else {
            return anchor.isExhausted ? .exhausted : .remaining(anchor.remainingText)
        }

        guard anchor.remainingText.hasPrefix(typedText) else {
            return .diverged(reason: .typedTextMismatch)
        }

        let remainingText = String(anchor.remainingText.dropFirst(typedText.count))
        return remainingText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? .exhausted
            : .remaining(remainingText)
    }
}
