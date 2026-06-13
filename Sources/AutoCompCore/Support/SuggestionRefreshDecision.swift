import CoreGraphics
import Foundation

public enum SuggestionRefreshKeepReason: String, Equatable, Sendable {
    case webWhitespaceNormalization = "web-whitespace-normalization"
    case sameFocusedText = "same-focused-text"
    case acceptedPrefixConsistent = "accepted-prefix-consistent"
}

public enum SuggestionRefreshDecision: Equatable, Sendable {
    case clearDismissalAndContinue
    case keepDismissed
    case evaluateEmptyContextEligibility
    case repairLeakedShortcut
    case repairCompletedAcceptAll
    case handleAcceptedSession
    case keepSuggestion(reason: SuggestionRefreshKeepReason, presentationContext: TextContext)
    case evaluateEligibility
    case ineligible(SuggestionEligibilityDecision)
    case requestCompletion
}

public struct SuggestionRefreshDecisionInput: Equatable, Sendable {
    public let context: TextContext
    public let previousContext: TextContext?
    public let currentSuggestion: Suggestion?
    public let dismissedContext: TextContext?
    public let acceptedPrefixConsistent: Bool
    public let leakedShortcutRepairNeeded: Bool
    public let completedAcceptAllRepairNeeded: Bool
    public let acceptedSessionCanHandle: Bool
    public let eligibilityDecision: SuggestionEligibilityDecision?

    public init(
        context: TextContext,
        previousContext: TextContext?,
        currentSuggestion: Suggestion?,
        dismissedContext: TextContext?,
        acceptedPrefixConsistent: Bool = false,
        leakedShortcutRepairNeeded: Bool = false,
        completedAcceptAllRepairNeeded: Bool = false,
        acceptedSessionCanHandle: Bool = false,
        eligibilityDecision: SuggestionEligibilityDecision? = nil
    ) {
        self.context = context
        self.previousContext = previousContext
        self.currentSuggestion = currentSuggestion
        self.dismissedContext = dismissedContext
        self.acceptedPrefixConsistent = acceptedPrefixConsistent
        self.leakedShortcutRepairNeeded = leakedShortcutRepairNeeded
        self.completedAcceptAllRepairNeeded = completedAcceptAllRepairNeeded
        self.acceptedSessionCanHandle = acceptedSessionCanHandle
        self.eligibilityDecision = eligibilityDecision
    }
}

public enum SuggestionRefreshDecisionEngine {
    public static func decide(_ input: SuggestionRefreshDecisionInput) -> SuggestionRefreshDecision {
        if let dismissedContext = input.dismissedContext {
            guard isSameFocusedText(input.context, as: dismissedContext) else {
                return .clearDismissalAndContinue
            }
            return .keepDismissed
        }

        if input.context.textBeforeCursor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .evaluateEmptyContextEligibility
        }

        if input.leakedShortcutRepairNeeded {
            return .repairLeakedShortcut
        }

        if input.completedAcceptAllRepairNeeded {
            return .repairCompletedAcceptAll
        }

        if let suggestion = input.currentSuggestion,
           !suggestion.isExhausted,
           let previousContext = input.previousContext,
           isWebWhitespaceNormalizationDrift(context: input.context, previousContext: previousContext) {
            return .keepSuggestion(
                reason: .webWhitespaceNormalization,
                presentationContext: input.context.replacingTextBeforeCursor(previousContext.textBeforeCursor)
            )
        }

        if input.acceptedSessionCanHandle {
            return .handleAcceptedSession
        }

        if let suggestion = input.currentSuggestion,
           !suggestion.isExhausted,
           let previousContext = input.previousContext,
           isSameFocusedText(input.context, as: previousContext) {
            return .keepSuggestion(reason: .sameFocusedText, presentationContext: input.context)
        }

        if let suggestion = input.currentSuggestion,
           !suggestion.isExhausted,
           input.previousContext != nil,
           input.acceptedPrefixConsistent {
            return .keepSuggestion(reason: .acceptedPrefixConsistent, presentationContext: input.context)
        }

        guard let eligibilityDecision = input.eligibilityDecision else {
            return .evaluateEligibility
        }

        return eligibilityDecision.isEligible
            ? .requestCompletion
            : .ineligible(eligibilityDecision)
    }

    private static func isWebWhitespaceNormalizationDrift(context: TextContext, previousContext: TextContext) -> Bool {
        guard WebHostApps.isWebLike(context.app.bundleID),
              InteractionTargetMatcher.matches(context, as: previousContext),
              textEndsWithSuggestionTriggerWhitespace(previousContext.textBeforeCursor),
              droppingTrailingWhitespace(from: previousContext.textBeforeCursor) == context.textBeforeCursor else {
            return false
        }

        return true
    }

    private static func isSameFocusedText(_ context: TextContext, as previousContext: TextContext) -> Bool {
        previousContext.textBeforeCursor == context.textBeforeCursor
            && previousContext.textAfterCursor == context.textAfterCursor
            && previousContext.selectedText == context.selectedText
            && InteractionTargetMatcher.matches(context, as: previousContext)
    }

    private static func textEndsWithSuggestionTriggerWhitespace(_ text: String) -> Bool {
        guard let lastScalar = text.unicodeScalars.last else {
            return false
        }
        return CharacterSet.whitespacesAndNewlines.contains(lastScalar)
    }

    private static func droppingTrailingWhitespace(from text: String) -> String {
        var scalars = text.unicodeScalars
        while let last = scalars.last, CharacterSet.whitespacesAndNewlines.contains(last) {
            scalars.removeLast()
        }
        return String(scalars)
    }

}

private extension TextContext {
    func replacingTextBeforeCursor(_ textBeforeCursor: String) -> TextContext {
        self.copy(textBeforeCursor: textBeforeCursor)
    }
}
