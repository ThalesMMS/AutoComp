import CoreGraphics
import Foundation

public enum SuggestionEligibilitySkipReason: String, Codable, CaseIterable, Sendable {
    case compatibility = "compatibility"
    case emptyContext = "empty-context"
    case inputSourceNonASCII = "input-source-non-ascii"
    case imeCompositionActive = "ime-composition-active"
    case selectionActive = "selection-active"
    case sentenceComplete = "sentence-complete"
    case unchangedContext = "unchanged-context"
    case awaitingSpaceTrigger = "awaiting-space-trigger"
    case manualOnlyWaitingForTrigger = "manual-only-waiting-for-trigger"
}

public enum SuggestionEligibilityTriggerReason: String, Codable, CaseIterable, Sendable {
    case manual = "manual"
    case recentSpaceKey = "recent-space-key"
}

public enum SuggestionEligibilityInvocation: String, Codable, CaseIterable, Sendable {
    case automatic
    case manual
}

public enum SuggestionEligibilityLogKind: Equatable, Sendable {
    case eligible
    case skip(SuggestionEligibilitySkipReason)
    case trigger(SuggestionEligibilityTriggerReason)
}

public struct SuggestionEligibilityLogData: Equatable, Sendable {
    public let kind: SuggestionEligibilityLogKind
    public let appDisplayName: String
    public let bundleID: String
    public let compatibilityEnabled: Bool?
    public let displayMode: SuggestionDisplayMode?
    public let compatibilityStatus: CompatibilityStatus?

    public init(
        kind: SuggestionEligibilityLogKind,
        appDisplayName: String,
        bundleID: String,
        compatibilityEnabled: Bool? = nil,
        displayMode: SuggestionDisplayMode? = nil,
        compatibilityStatus: CompatibilityStatus? = nil
    ) {
        self.kind = kind
        self.appDisplayName = appDisplayName
        self.bundleID = bundleID
        self.compatibilityEnabled = compatibilityEnabled
        self.displayMode = displayMode
        self.compatibilityStatus = compatibilityStatus
    }
}

public enum SuggestionEligibilityOutcome: Equatable, Sendable {
    case eligible
    case ineligible(SuggestionEligibilitySkipReason)
}

public struct SuggestionEligibilityDecision: Equatable, Sendable {
    public let outcome: SuggestionEligibilityOutcome
    public let statusMessage: String?
    public let logs: [SuggestionEligibilityLogData]

    public init(
        outcome: SuggestionEligibilityOutcome,
        statusMessage: String? = nil,
        logs: [SuggestionEligibilityLogData]
    ) {
        self.outcome = outcome
        self.statusMessage = statusMessage
        self.logs = logs
    }

    public var isEligible: Bool {
        outcome == .eligible
    }

    public var skipReason: SuggestionEligibilitySkipReason? {
        if case .ineligible(let reason) = outcome {
            return reason
        }
        return nil
    }
}

public struct SuggestionEligibilityEvaluator: Sendable {
    private let suggestionTriggerKeyGraceInterval: TimeInterval

    public init(suggestionTriggerKeyGraceInterval: TimeInterval = 1.2) {
        self.suggestionTriggerKeyGraceInterval = suggestionTriggerKeyGraceInterval
    }

    public func evaluate(
        context: TextContext,
        previousContext: TextContext?,
        compatibilityDecision: CompatibilityDecision,
        lastSuggestionTriggerKeyAt: Date,
        invocation: SuggestionEligibilityInvocation = .automatic,
        inputMethodState: InputMethodState = .asciiCompatible,
        now: Date = Date()
    ) -> SuggestionEligibilityDecision {
        let trimmed = context.textBeforeCursor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return skip(.emptyContext, context: context, statusMessage: "Waiting for text")
        }

        guard compatibilityDecision.enabled,
              compatibilityDecision.mode != .disabled,
              compatibilityDecision.profile.status != .unsupported else {
            let statusMessage = compatibilityDecision.profile.notes.isEmpty
                ? "Disabled for \(context.app.displayName)"
                : compatibilityDecision.profile.notes
            return skip(
                .compatibility,
                context: context,
                statusMessage: statusMessage,
                compatibilityDecision: compatibilityDecision
            )
        }

        guard invocation == .manual || compatibilityDecision.allowsAutomaticSuggestions else {
            return skip(
                .manualOnlyWaitingForTrigger,
                context: context,
                statusMessage: "Manual-only waiting for trigger",
                compatibilityDecision: compatibilityDecision
            )
        }

        guard !inputMethodState.isComposingText else {
            return skip(
                .imeCompositionActive,
                context: context,
                statusMessage: "IME composition active"
            )
        }

        guard invocation == .manual || inputMethodState.isASCIICompatible else {
            return skip(
                .inputSourceNonASCII,
                context: context,
                statusMessage: "IME: non-ASCII"
            )
        }

        guard invocation == .manual || !hasActiveSelection(context) else {
            return skip(
                .selectionActive,
                context: context,
                statusMessage: "Selection active"
            )
        }

        if invocation == .manual {
            return SuggestionEligibilityDecision(
                outcome: .eligible,
                logs: [
                    eligibleLog(context: context),
                    triggerLog(.manual, context: context)
                ]
            )
        }

        guard !TextContinuationHeuristics.shouldSuppressAutocomplete(after: context.textBeforeCursor) else {
            return skip(.sentenceComplete, context: context, statusMessage: "Sentence complete")
        }

        if let previousContext,
           previousContext.textBeforeCursor == context.textBeforeCursor,
           previousContext.app == context.app,
           previousContext.domain == context.domain {
            return skip(.unchangedContext, context: context)
        }

        var logs = [eligibleLog(context: context)]
        guard textEndsWithSuggestionTriggerWhitespace(context.textBeforeCursor) else {
            logs.append(skipLog(.awaitingSpaceTrigger, context: context))
            return SuggestionEligibilityDecision(
                outcome: .ineligible(.awaitingSpaceTrigger),
                statusMessage: "Waiting for space",
                logs: logs
            )
        }

        if let previousContext,
           isSameInteractionTarget(context, as: previousContext),
           previousContext.textBeforeCursor != context.textBeforeCursor {
            return SuggestionEligibilityDecision(outcome: .eligible, logs: logs)
        }

        if let previousContext,
           isDelayedGoogleDocsTextProgression(context, from: previousContext) {
            return SuggestionEligibilityDecision(outcome: .eligible, logs: logs)
        }

        let hasRecentTriggerKey = now.timeIntervalSince(lastSuggestionTriggerKeyAt) <= suggestionTriggerKeyGraceInterval
        if hasRecentTriggerKey {
            logs.append(triggerLog(.recentSpaceKey, context: context))
            return SuggestionEligibilityDecision(outcome: .eligible, logs: logs)
        }

        logs.append(skipLog(.awaitingSpaceTrigger, context: context))
        return SuggestionEligibilityDecision(
            outcome: .ineligible(.awaitingSpaceTrigger),
            statusMessage: "Waiting for space",
            logs: logs
        )
    }

    private func skip(
        _ reason: SuggestionEligibilitySkipReason,
        context: TextContext,
        statusMessage: String? = nil,
        compatibilityDecision: CompatibilityDecision? = nil
    ) -> SuggestionEligibilityDecision {
        SuggestionEligibilityDecision(
            outcome: .ineligible(reason),
            statusMessage: statusMessage,
            logs: [
                skipLog(
                    reason,
                    context: context,
                    compatibilityDecision: compatibilityDecision
                )
            ]
        )
    }

    private func eligibleLog(context: TextContext) -> SuggestionEligibilityLogData {
        SuggestionEligibilityLogData(
            kind: .eligible,
            appDisplayName: context.app.displayName,
            bundleID: context.app.bundleID
        )
    }

    private func triggerLog(
        _ reason: SuggestionEligibilityTriggerReason,
        context: TextContext
    ) -> SuggestionEligibilityLogData {
        SuggestionEligibilityLogData(
            kind: .trigger(reason),
            appDisplayName: context.app.displayName,
            bundleID: context.app.bundleID
        )
    }

    private func skipLog(
        _ reason: SuggestionEligibilitySkipReason,
        context: TextContext,
        compatibilityDecision: CompatibilityDecision? = nil
    ) -> SuggestionEligibilityLogData {
        SuggestionEligibilityLogData(
            kind: .skip(reason),
            appDisplayName: context.app.displayName,
            bundleID: context.app.bundleID,
            compatibilityEnabled: compatibilityDecision?.enabled,
            displayMode: compatibilityDecision?.mode,
            compatibilityStatus: compatibilityDecision?.profile.status
        )
    }

    private func textEndsWithSuggestionTriggerWhitespace(_ text: String) -> Bool {
        guard let lastScalar = text.unicodeScalars.last else {
            return false
        }
        return CharacterSet.whitespacesAndNewlines.contains(lastScalar)
    }

    private func hasActiveSelection(_ context: TextContext) -> Bool {
        (context.selectedRange?.length ?? 0) > 0
            || context.selectedText?.isEmpty == false
    }

    private func isSameInteractionTarget(_ context: TextContext, as previousContext: TextContext) -> Bool {
        guard context.app == previousContext.app,
              context.domain == previousContext.domain else {
            return false
        }

        if context.focusedElementID == previousContext.focusedElementID {
            return true
        }

        if approximatelySameRect(context.focusedElementRect, previousContext.focusedElementRect) {
            return true
        }

        return isSameGoogleDocsBrailleLineTarget(
            app: context.app,
            domain: context.domain,
            context.focusedElementRect,
            previousContext.focusedElementRect
        )
    }

    private func isDelayedGoogleDocsTextProgression(
        _ context: TextContext,
        from previousContext: TextContext
    ) -> Bool {
        guard context.domain == previousContext.domain,
              context.domain?.contains("docs.google.com") == true,
              isGoogleDocsCapableBrowser(context.app.bundleID),
              isGoogleDocsCapableBrowser(previousContext.app.bundleID),
              context.textBeforeCursor != previousContext.textBeforeCursor,
              context.textBeforeCursor.count > previousContext.textBeforeCursor.count else {
            return false
        }

        return true
    }

    private func isGoogleDocsCapableBrowser(_ bundleID: String) -> Bool {
        [
            "com.apple.Safari",
            "com.google.Chrome",
            "com.brave.Browser",
            "com.microsoft.edgemac",
            "company.thebrowser.Browser",
            "company.thebrowser.dia"
        ].contains(bundleID)
    }

    private func approximatelySameRect(_ lhs: CGRect?, _ rhs: CGRect?) -> Bool {
        guard let lhs, let rhs else {
            return false
        }

        let tolerance: CGFloat = 8
        return abs(lhs.minX - rhs.minX) <= tolerance
            && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance
            && abs(lhs.height - rhs.height) <= tolerance
    }

    private func isSameGoogleDocsBrailleLineTarget(
        app: AppIdentity,
        domain: String?,
        _ lhs: CGRect?,
        _ rhs: CGRect?
    ) -> Bool {
        guard app.bundleID == "com.google.Chrome",
              domain?.contains("docs.google.com") == true,
              let lhs,
              let rhs else {
            return false
        }

        return isGoogleDocsBrailleLineMetric(lhs)
            && isGoogleDocsBrailleLineMetric(rhs)
    }

    private func isGoogleDocsBrailleLineMetric(_ rect: CGRect) -> Bool {
        rect.minX.isFinite
            && rect.minY.isFinite
            && rect.width.isFinite
            && rect.height.isFinite
            && rect.width >= 80
            && rect.height > 0
            && rect.height <= 4
    }
}
