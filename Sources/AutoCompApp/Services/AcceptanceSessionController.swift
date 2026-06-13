import AutoCompCore
import CoreGraphics
import Foundation

struct AcceptanceSessionHandledResult: Equatable {
    let currentSuggestion: Suggestion?
    let statusMessage: String
    let shouldSchedulePrediction: Bool

    init(
        currentSuggestion: Suggestion?,
        statusMessage: String,
        shouldSchedulePrediction: Bool = false
    ) {
        self.currentSuggestion = currentSuggestion
        self.statusMessage = statusMessage
        self.shouldSchedulePrediction = shouldSchedulePrediction
    }
}

enum AcceptanceSessionObservationResult: Equatable {
    case notActive
    case handled(AcceptanceSessionHandledResult)
    case cleared
}

enum CompletedAcceptAllLeakResult: Equatable {
    case notActive
    case handled
    case cleared
}

enum LeakedShortcutRepairResult: Equatable {
    case repaired(
        repairedContext: TextContext,
        currentSuggestion: Suggestion?,
        statusMessage: String
    )
    case failed(statusMessage: String)
}

private let acceptanceGuardLogger = AutoCompLogger(category: "acceptance-guard")

enum AcceptanceSessionValidationResult: Equatable {
    case valid
    case passedThrough(AcceptanceSessionPassThroughReason)
}

enum AcceptanceSessionPassThroughReason: String {
    case noSuggestion = "no-suggestion"
    case staleContext = "stale-context"
    case staleSuggestion = "stale-suggestion"
    case targetChanged = "target-changed"
    case unexpectedSelection = "unexpected-selection"
}

@MainActor
final class AcceptanceSessionController {
    private var acceptanceState: AcceptanceState?
    private var completedAcceptAllState: CompletedAcceptAllState?
    private let suggestionSessionReconciler: SuggestionSessionReconciler
    private let completedAcceptAllLeakGraceInterval: TimeInterval

    init(
        suggestionSessionReconciler: SuggestionSessionReconciler = SuggestionSessionReconciler(),
        completedAcceptAllLeakGraceInterval: TimeInterval = 8.0
    ) {
        self.suggestionSessionReconciler = suggestionSessionReconciler
        self.completedAcceptAllLeakGraceInterval = completedAcceptAllLeakGraceInterval
    }

    func clearAll() {
        acceptanceState = nil
        completedAcceptAllState = nil
    }

    func clearAcceptance() {
        acceptanceState = nil
    }

    func recordPublication(
        context: TextContext,
        suggestion: Suggestion,
        now: Date = Date()
    ) {
        let anchor = SuggestionAnchor(context: context, suggestion: suggestion)
        let session = ActiveSuggestionSession(
            anchor: anchor,
            latencyMs: suggestion.latencyMs,
            lastAcceptedAt: now
        )

        acceptanceState = AcceptanceState(
            focusIdentity: FocusIdentity(context: context),
            session: session,
            source: .publication
        )
        completedAcceptAllState = nil
    }

    func recordAcceptance(
        previousContext: TextContext?,
        previousSuggestion: Suggestion,
        updatedSuggestion: Suggestion,
        acceptedText: String,
        now: Date = Date()
    ) {
        guard let previousContext else {
            return
        }

        let baseText = acceptanceState?.session.baseTextBeforeCursor ?? previousContext.textBeforeCursor
        let acceptedPrefix = (acceptanceState?.session.acceptedText ?? previousSuggestion.acceptedPrefix) + acceptedText
        let fullText = previousSuggestion.acceptedPrefix + previousSuggestion.remainingText
        let anchor = SuggestionAnchor(
            target: ActiveSuggestionTarget(context: previousContext),
            baseTextBeforeCursor: baseText,
            fullText: fullText,
            acceptedText: acceptedPrefix,
            remainingText: updatedSuggestion.remainingText
        )
        let session = ActiveSuggestionSession(
            anchor: anchor,
            latencyMs: previousSuggestion.latencyMs,
            lastAcceptedAt: now
        )

        acceptanceState = AcceptanceState(
            focusIdentity: FocusIdentity(context: previousContext),
            session: session,
            source: .acceptance
        )
    }

    func armCompletedAcceptAll() -> Bool {
        completedAcceptAllState = acceptanceState.map {
            CompletedAcceptAllState(
                focusIdentity: $0.focusIdentity,
                app: $0.session.target.app,
                domain: $0.session.target.domain,
                baseTextBeforeCursor: $0.session.baseTextBeforeCursor,
                expectedTextBeforeCursor: $0.session.expectedTextBeforeCursor,
                lastAcceptedAt: $0.session.lastAcceptedAt
            )
        }
        acceptanceState = nil
        return completedAcceptAllState != nil
    }

    func validateAcceptance(
        context: TextContext,
        currentSuggestion: Suggestion?,
        now: Date = Date()
    ) -> AcceptanceSessionValidationResult {
        guard let currentSuggestion else {
            clearAll()
            return .passedThrough(.noSuggestion)
        }

        guard let state = acceptanceState else {
            return .passedThrough(.staleContext)
        }

        guard context.app == state.session.target.app,
              context.domain == state.session.target.domain else {
            clearAll()
            acceptanceGuardLogger.info("acceptance rejected reason=target-changed")
            return .passedThrough(.targetChanged)
        }

        let sameFocusedElement = InteractionTargetMatcher.matches(
            context,
            app: state.session.target.app,
            domain: state.session.target.domain,
            focusIdentity: state.focusIdentity
        )
            || isSameGoogleDocsTextTarget(context: context, state: state)
        guard sameFocusedElement else {
            clearAll()
            acceptanceGuardLogger.info("acceptance rejected reason=target-changed")
            return .passedThrough(.targetChanged)
        }

        if hasActiveSelection(context) {
            guard isOriginalReplacementSelection(context: context, state: state) else {
                clearAll()
                return .passedThrough(.unexpectedSelection)
            }
            return .valid
        }

        guard currentSuggestion.acceptedPrefix == state.session.acceptedText,
              currentSuggestion.remainingText == state.session.remainingText else {
            clearAll()
            return .passedThrough(.staleSuggestion)
        }

        let relation = suggestionSessionReconciler.reconcile(
            context: context,
            session: state.session,
            now: now,
            targetMatches: sameFocusedElement
        )

        switch relation {
        case .settled, .pendingEcho, .trailingWhitespace:
            return .valid
        case .targetChanged:
            clearAll()
            acceptanceGuardLogger.info("acceptance rejected reason=target-changed")
            return .passedThrough(.targetChanged)
        case .typedThrough, .diverged, .exhausted:
            clearAll()
            return .passedThrough(.staleContext)
        }
    }

    private func hasActiveSelection(_ context: TextContext) -> Bool {
        (context.selectedRange?.length ?? 0) > 0
            || context.selectedText?.isEmpty == false
    }

    private func isOriginalReplacementSelection(
        context: TextContext,
        state: AcceptanceState
    ) -> Bool {
        guard state.source == .publication,
              context.textBeforeCursor == state.session.baseTextBeforeCursor,
              context.selectedRange == state.session.target.selectedRange,
              context.selectedText == state.session.target.selectedText else {
            return false
        }

        return (state.session.target.selectedRange?.length ?? 0) > 0
            || state.session.target.selectedText?.isEmpty == false
    }

    func repairLeakedShortcutIfNeeded(
        context: TextContext,
        previousContext: TextContext?,
        currentSuggestion: Suggestion?,
        repairInserter: ShortcutLeakRepairing?
    ) async -> LeakedShortcutRepairResult? {
        guard let repairInserter,
              let previousContext,
              var suggestion = currentSuggestion,
              !suggestion.isExhausted,
              InteractionTargetMatcher.matches(context, as: previousContext),
              let leakedShortcut = leakedShortcut(
                in: context.textBeforeCursor,
                previousText: previousContext.textBeforeCursor,
                appBundleID: context.app.bundleID
              ) else {
            return nil
        }

        let suffixScalars = leakedShortcut.suffix.unicodeScalars.map { String($0.value) }.joined(separator: ",")
        GeometryDebug.log("shortcut-repair detected suffixScalars=\(suffixScalars)")

        do {
            let previousSuggestion = suggestion
            let leakedLength = (leakedShortcut.suffix as NSString).length
            let acceptedText = try await repairInserter.replaceLeakedShortcutSuffix(
                length: leakedLength,
                withNextWordsFrom: &suggestion
            )

            guard let acceptedText else {
                return nil
            }

            recordAcceptance(
                previousContext: previousContext,
                previousSuggestion: previousSuggestion,
                updatedSuggestion: suggestion,
                acceptedText: acceptedText
            )

            let repairedContext = context.replacingTextBeforeCursor(
                previousContext.textBeforeCursor + acceptedText
            )
            GeometryDebug.log("shortcut-repair action=\(leakedShortcut.action.debugName)")
            return .repaired(
                repairedContext: repairedContext,
                currentSuggestion: suggestion.isExhausted ? nil : suggestion,
                statusMessage: leakedShortcut.action.statusMessage
            )
        } catch {
            return .failed(statusMessage: "Insertion failed")
        }
    }

    func repairCompletedAcceptAllLeakIfNeeded(
        context: TextContext,
        now: Date = Date()
    ) -> CompletedAcceptAllLeakResult {
        guard let state = completedAcceptAllState else {
            return .notActive
        }

        GeometryDebug.log("completed-accept-all check observedLength=\((context.textBeforeCursor as NSString).length) expectedLength=\((state.expectedTextBeforeCursor as NSString).length)")

        switch evaluateCompletedAcceptAllLeak(context: context, state: state, now: now) {
        case .settled:
            GeometryDebug.log("completed-accept-all settled")
            return .handled
        case .delayedEcho:
            return .handled
        case .invalid(.targetAppDomain):
            GeometryDebug.log("completed-accept-all cleared reason=target-app-domain")
            completedAcceptAllState = nil
            return .cleared
        case .invalid(.focusedTarget):
            GeometryDebug.log("completed-accept-all cleared reason=focused-target")
            completedAcceptAllState = nil
            return .cleared
        case .invalid(.diverged):
            completedAcceptAllState = nil
            GeometryDebug.log("completed-accept-all cleared reason=diverged")
            return .cleared
        }
    }

    func isTextConsistentWithAcceptedSuggestion(
        context: TextContext,
        previousContext: TextContext,
        suggestion: Suggestion
    ) -> Bool {
        guard context.app == previousContext.app,
              context.domain == previousContext.domain,
              InteractionTargetMatcher.matches(context, as: previousContext) else {
            return false
        }

        guard !suggestion.acceptedPrefix.isEmpty else {
            return false
        }

        let expectedText = acceptanceState?.session.expectedTextBeforeCursor
            ?? previousContext.textBeforeCursor + suggestion.acceptedPrefix

        if context.textBeforeCursor == expectedText {
            return true
        }

        if context.textBeforeCursor.hasPrefix(expectedText) {
            let suffix = context.textBeforeCursor.dropFirst(expectedText.count)
            return suffix.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
        }

        return false
    }

    func handleAcceptedSuggestionSession(
        context: TextContext,
        currentSuggestion: Suggestion?,
        now: Date = Date()
    ) -> AcceptanceSessionObservationResult {
        guard let state = acceptanceState else {
            return .notActive
        }

        guard context.app == state.session.target.app,
              context.domain == state.session.target.domain else {
            acceptanceState = nil
            return .cleared
        }

        if state.source == .publication,
           context.textBeforeCursor == state.session.baseTextBeforeCursor {
            return .notActive
        }

        let sameFocusedElement = InteractionTargetMatcher.matches(
            context,
            app: state.session.target.app,
            domain: state.session.target.domain,
            focusIdentity: state.focusIdentity
        )
            || isSameGoogleDocsTextTarget(context: context, state: state)
        guard sameFocusedElement else {
            acceptanceState = nil
            return .cleared
        }

        let relation = suggestionSessionReconciler.reconcile(
            context: context,
            session: state.session,
            now: now,
            targetMatches: sameFocusedElement
        )

        switch relation {
        case .settled, .pendingEcho:
            guard state.source == .acceptance else {
                return .notActive
            }

            return .handled(
                AcceptanceSessionHandledResult(
                    currentSuggestion: currentSuggestion?.isExhausted == false ? currentSuggestion : nil,
                    statusMessage: "Continuing accepted suggestion"
                )
            )
        case .exhausted:
            guard state.source == .acceptance else {
                acceptanceState = nil
                return .cleared
            }

            acceptanceState = nil
            return .handled(
                AcceptanceSessionHandledResult(
                    currentSuggestion: nil,
                    statusMessage: "Continuing accepted suggestion"
                )
            )
        case .trailingWhitespace:
            guard state.source == .acceptance else {
                return .notActive
            }

            return .handled(
                AcceptanceSessionHandledResult(
                    currentSuggestion: currentSuggestion?.isExhausted == false ? currentSuggestion : nil,
                    statusMessage: "Ignoring accepted suggestion echo"
                )
            )
        case .typedThrough(let session, let typedText):
            let sessionIsExhausted = session.isExhausted
            acceptanceState = session.isExhausted ? nil : AcceptanceState(
                focusIdentity: FocusIdentity(context: context),
                session: session,
                source: state.source
            )

            let updatedSuggestion = suggestionAfterTypingThrough(
                currentSuggestion,
                typedText: typedText
            )
            return .handled(
                AcceptanceSessionHandledResult(
                    currentSuggestion: updatedSuggestion,
                    statusMessage: "Continuing accepted suggestion",
                    shouldSchedulePrediction: sessionIsExhausted
                )
            )
        case .diverged, .targetChanged:
            acceptanceState = nil
            return .cleared
        }
    }

    func shouldHandleAcceptedSuggestionSession(context: TextContext) -> Bool {
        guard let state = acceptanceState else {
            return false
        }

        guard context.app == state.session.target.app,
              context.domain == state.session.target.domain else {
            // Different app/domain: route through the handler so it clears the stale session.
            return true
        }

        return !(state.source == .publication
            && context.textBeforeCursor == state.session.baseTextBeforeCursor)
    }

    func canRepairLeakedShortcut(
        context: TextContext,
        previousContext: TextContext?,
        currentSuggestion: Suggestion?,
        repairInserter: ShortcutLeakRepairing?
    ) -> Bool {
        guard repairInserter != nil,
              let previousContext,
              let suggestion = currentSuggestion,
              !suggestion.isExhausted,
              InteractionTargetMatcher.matches(context, as: previousContext),
              leakedShortcut(
                in: context.textBeforeCursor,
                previousText: previousContext.textBeforeCursor,
                appBundleID: context.app.bundleID
              ) != nil else {
            return false
        }

        return true
    }

    func canRepairCompletedAcceptAllLeak(
        context: TextContext,
        now: Date = Date()
    ) -> Bool {
        guard let state = completedAcceptAllState else {
            return false
        }

        switch evaluateCompletedAcceptAllLeak(context: context, state: state, now: now) {
        case .settled, .delayedEcho:
            return true
        case .invalid:
            return false
        }
    }

    func clearCompletedAcceptAllLeakIfInvalid(
        context: TextContext,
        now: Date = Date()
    ) {
        guard let state = completedAcceptAllState else {
            return
        }

        guard case .invalid(let reason) = evaluateCompletedAcceptAllLeak(context: context, state: state, now: now) else {
            return
        }

        completedAcceptAllState = nil
        GeometryDebug.log("completed-accept-all cleared reason=\(reason.rawValue)")
    }

    private func suggestionAfterTypingThrough(
        _ currentSuggestion: Suggestion?,
        typedText: String
    ) -> Suggestion? {
        guard var currentSuggestion,
              currentSuggestion.remainingText.hasPrefix(typedText) else {
            return nil
        }

        currentSuggestion.acceptedPrefix += typedText
        currentSuggestion.remainingText.removeFirst(typedText.count)
        currentSuggestion.visibleText = currentSuggestion.remainingText
        currentSuggestion.collapseAlternativesToCurrentText()
        return currentSuggestion.isExhausted ? nil : currentSuggestion
    }

    private func completedAcceptAllTextMatchesExpected(
        _ observedText: String,
        state: CompletedAcceptAllState
    ) -> Bool {
        SuggestionSessionReconciler.textMatchesExpectedOrOnlyAddsTrailingWhitespace(
            observedText,
            expectedText: state.expectedTextBeforeCursor
        ) || SuggestionSessionReconciler.textMatchesExpectedOrOnlyAddsTrailingWhitespace(
            SuggestionSessionReconciler.normalizedWhitespace(in: observedText),
            expectedText: SuggestionSessionReconciler.normalizedWhitespace(in: state.expectedTextBeforeCursor)
        )
    }

    private func isCompletedAcceptAllPotentialDelayedEcho(
        _ observedText: String,
        state: CompletedAcceptAllState
    ) -> Bool {
        if state.expectedTextBeforeCursor.hasPrefix(observedText),
           observedText.hasPrefix(state.baseTextBeforeCursor) {
            return true
        }

        let normalizedObservedText = SuggestionSessionReconciler.normalizedWhitespace(in: observedText)
        let normalizedExpectedText = SuggestionSessionReconciler.normalizedWhitespace(in: state.expectedTextBeforeCursor)
        let normalizedBaseText = SuggestionSessionReconciler.normalizedWhitespace(in: state.baseTextBeforeCursor)
        return normalizedExpectedText.hasPrefix(normalizedObservedText)
            && normalizedObservedText.hasPrefix(normalizedBaseText)
    }

    private func evaluateCompletedAcceptAllLeak(
        context: TextContext,
        state: CompletedAcceptAllState,
        now: Date
    ) -> CompletedAcceptAllLeakEvaluation {
        guard context.app == state.app,
              context.domain == state.domain else {
            return .invalid(.targetAppDomain)
        }

        guard InteractionTargetMatcher.matches(
            context,
            app: state.app,
            domain: state.domain,
            focusIdentity: state.focusIdentity
        )
            || isSameGoogleDocsCompletedAcceptAllTextTarget(context: context, state: state) else {
            return .invalid(.focusedTarget)
        }

        if completedAcceptAllTextMatchesExpected(context.textBeforeCursor, state: state) {
            return .settled
        }

        let isPotentialDelayedEcho = isCompletedAcceptAllPotentialDelayedEcho(
            context.textBeforeCursor,
            state: state
        )
        if isPotentialDelayedEcho,
           now.timeIntervalSince(state.lastAcceptedAt) <= completedAcceptAllLeakGraceInterval {
            return .delayedEcho
        }

        return .invalid(.diverged)
    }

    private func leakedShortcut(in observedText: String, previousText: String, appBundleID: String) -> LeakedShortcut? {
        guard observedText.hasPrefix(previousText) else {
            return nil
        }

        let suffix = String(observedText.dropFirst(previousText.count))
        guard !suffix.isEmpty else {
            return nil
        }

        if suffix.allSatisfy({ $0 == "\t" }) {
            return LeakedShortcut(suffix: suffix, action: .acceptNextWords)
        }

        // Notes can expose leaked Tab acceptance as a mix of plain spaces and
        // tab characters in its AX text stream. Limit this repair to Notes,
        // where Tab has no text-entry meaning while a completion is visible.
        if appBundleID == "com.apple.Notes", suffix.allSatisfy({ $0 == " " || $0 == "\t" }) {
            return LeakedShortcut(suffix: suffix, action: .acceptNextWords)
        }

        return nil
    }

    private func isSameGoogleDocsTextTarget(context: TextContext, state: AcceptanceState) -> Bool {
        guard isGoogleDocsWebLikeContext(app: state.session.target.app, domain: state.session.target.domain),
              context.app == state.session.target.app,
              context.domain == state.session.target.domain,
              isSelectionCompatible(context.selectedText, state.session.target.selectedText) else {
            return false
        }

        return context.textBeforeCursor == state.session.baseTextBeforeCursor
            || context.textBeforeCursor == state.session.expectedTextBeforeCursor
    }

    private func isSameGoogleDocsCompletedAcceptAllTextTarget(
        context: TextContext,
        state: CompletedAcceptAllState
    ) -> Bool {
        guard isGoogleDocsWebLikeContext(app: state.app, domain: state.domain),
              context.app == state.app,
              context.domain == state.domain else {
            return false
        }

        return completedAcceptAllTextMatchesExpected(context.textBeforeCursor, state: state)
            || isCompletedAcceptAllPotentialDelayedEcho(context.textBeforeCursor, state: state)
    }

    private func isGoogleDocsWebLikeContext(app: AppIdentity, domain: String?) -> Bool {
        GoogleDocsContext.matches(bundleID: app.bundleID, domain: domain, appGate: .webLike)
    }

    private func isSelectionCompatible(_ lhs: String?, _ rhs: String?) -> Bool {
        ((lhs?.isEmpty ?? true) && (rhs?.isEmpty ?? true)) || lhs == rhs
    }

}

private struct AcceptanceState {
    let focusIdentity: FocusIdentity
    let session: ActiveSuggestionSession
    let source: AcceptanceSessionSource
}

private enum AcceptanceSessionSource {
    case publication
    case acceptance
}

private struct CompletedAcceptAllState {
    let focusIdentity: FocusIdentity
    let app: AppIdentity
    let domain: String?
    let baseTextBeforeCursor: String
    let expectedTextBeforeCursor: String
    let lastAcceptedAt: Date
}

private enum CompletedAcceptAllLeakEvaluation {
    case settled
    case delayedEcho
    case invalid(CompletedAcceptAllClearReason)
}

private enum CompletedAcceptAllClearReason: String {
    case targetAppDomain = "target-app-domain"
    case focusedTarget = "focused-target"
    case diverged
}

private struct LeakedShortcut {
    let suffix: String
    let action: LeakedShortcutAction
}

private enum LeakedShortcutAction {
    case acceptNextWords

    var debugName: String {
        "replace-leaked-tab"
    }

    var statusMessage: String {
        "Accepted leaked shortcut"
    }
}

extension TextContext {
    func replacingTextBeforeCursor(_ textBeforeCursor: String) -> TextContext {
        self.copy(textBeforeCursor: textBeforeCursor)
    }
}
