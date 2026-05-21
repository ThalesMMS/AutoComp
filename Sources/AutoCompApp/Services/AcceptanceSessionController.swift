import AutoCompCore
import CoreGraphics
import Foundation

struct AcceptanceSessionHandledResult: Equatable {
    let currentSuggestion: Suggestion?
    let statusMessage: String
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
        let session = ActiveSuggestionSession(
            baseContext: context,
            fullText: suggestion.acceptedPrefix + suggestion.remainingText,
            acceptedText: suggestion.acceptedPrefix,
            remainingText: suggestion.remainingText,
            latencyMs: suggestion.latencyMs,
            lastAcceptedAt: now
        )

        acceptanceState = AcceptanceState(
            focusIdentity: FocusIdentity(context: context),
            session: session
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
        let session = ActiveSuggestionSession(
            target: ActiveSuggestionTarget(context: previousContext),
            baseTextBeforeCursor: baseText,
            fullText: fullText,
            acceptedText: acceptedPrefix,
            remainingText: updatedSuggestion.remainingText,
            latencyMs: previousSuggestion.latencyMs,
            lastAcceptedAt: now
        )

        acceptanceState = AcceptanceState(
            focusIdentity: FocusIdentity(context: previousContext),
            session: session
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
              isSameInteractionTarget(context, as: previousContext),
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

        guard context.app == state.app,
              context.domain == state.domain else {
            GeometryDebug.log("completed-accept-all cleared reason=target-app-domain")
            completedAcceptAllState = nil
            return .cleared
        }

        guard sameFocusedElement(context: context, stateFocusIdentity: state.focusIdentity) else {
            GeometryDebug.log("completed-accept-all cleared reason=focused-target")
            completedAcceptAllState = nil
            return .cleared
        }

        if completedAcceptAllTextMatchesExpected(context.textBeforeCursor, state: state) {
            GeometryDebug.log("completed-accept-all settled")
            if now.timeIntervalSince(state.lastAcceptedAt) > completedAcceptAllLeakGraceInterval {
                completedAcceptAllState = nil
            }
            return .handled
        }

        let isPotentialDelayedEcho = isCompletedAcceptAllPotentialDelayedEcho(
            context.textBeforeCursor,
            state: state
        )
        if isPotentialDelayedEcho,
           now.timeIntervalSince(state.lastAcceptedAt) <= completedAcceptAllLeakGraceInterval {
            return .handled
        }

        completedAcceptAllState = nil
        GeometryDebug.log("completed-accept-all cleared reason=diverged")
        return .cleared
    }

    func isTextConsistentWithAcceptedSuggestion(
        context: TextContext,
        previousContext: TextContext,
        suggestion: Suggestion
    ) -> Bool {
        guard context.app == previousContext.app,
              context.domain == previousContext.domain,
              isSameInteractionTarget(context, as: previousContext) else {
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

        let sameFocusedElement = sameFocusedElement(context: context, stateFocusIdentity: state.focusIdentity)
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
            return .handled(
                AcceptanceSessionHandledResult(
                    currentSuggestion: currentSuggestion?.isExhausted == false ? currentSuggestion : nil,
                    statusMessage: "Continuing accepted suggestion"
                )
            )
        case .exhausted:
            acceptanceState = nil
            return .handled(
                AcceptanceSessionHandledResult(
                    currentSuggestion: nil,
                    statusMessage: "Continuing accepted suggestion"
                )
            )
        case .trailingWhitespace:
            return .handled(
                AcceptanceSessionHandledResult(
                    currentSuggestion: currentSuggestion?.isExhausted == false ? currentSuggestion : nil,
                    statusMessage: "Ignoring accepted suggestion echo"
                )
            )
        case .typedThrough(let session, let typedText):
            acceptanceState = session.isExhausted ? nil : AcceptanceState(
                focusIdentity: FocusIdentity(context: context),
                session: session
            )

            let updatedSuggestion = suggestionAfterTypingThrough(
                currentSuggestion,
                typedText: typedText
            )
            return .handled(
                AcceptanceSessionHandledResult(
                    currentSuggestion: updatedSuggestion,
                    statusMessage: "Continuing accepted suggestion"
                )
            )
        case .diverged, .targetChanged:
            acceptanceState = nil
            return .cleared
        }
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

    private func isSameInteractionTarget(_ context: TextContext, as previousContext: TextContext) -> Bool {
        guard context.app == previousContext.app,
              context.domain == previousContext.domain else {
            return false
        }

        return sameFocusedElement(
            context: context,
            stateFocusIdentity: FocusIdentity(context: previousContext)
        )
    }

    private func sameFocusedElement(context: TextContext, stateFocusIdentity: FocusIdentity) -> Bool {
        FocusIdentity(context: context).matches(stateFocusIdentity)
            || approximatelySameRect(context.focusedElementRect, stateFocusIdentity.focusedElementRect)
            || isSameGoogleDocsBrailleLineTarget(
                app: context.app,
                domain: context.domain,
                context.focusedElementRect,
                stateFocusIdentity.focusedElementRect
            )
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

private struct AcceptanceState {
    let focusIdentity: FocusIdentity
    let session: ActiveSuggestionSession
}

private struct CompletedAcceptAllState {
    let focusIdentity: FocusIdentity
    let app: AppIdentity
    let domain: String?
    let baseTextBeforeCursor: String
    let expectedTextBeforeCursor: String
    let lastAcceptedAt: Date
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
        "Accepted leaked Tab"
    }
}

extension TextContext {
    func replacingTextBeforeCursor(_ textBeforeCursor: String) -> TextContext {
        TextContext(
            id: id,
            app: app,
            domain: domain,
            focusedElementID: focusedElementID,
            textBeforeCursor: textBeforeCursor,
            selectedRange: selectedRange,
            caretRect: caretRect,
            focusedElementRect: focusedElementRect,
            previousGlyphRect: previousGlyphRect,
            nextGlyphRect: nextGlyphRect,
            lineReferenceRect: lineReferenceRect,
            caretGeometryQuality: caretGeometryQuality,
            observedCharacterWidth: observedCharacterWidth,
            languageHint: languageHint,
            captureSources: captureSources,
            createdAt: createdAt
        )
    }
}
