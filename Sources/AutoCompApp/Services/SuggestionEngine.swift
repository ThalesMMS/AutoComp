import AutoCompCore
import CoreGraphics
import Foundation

@MainActor
final class SuggestionEngine: ObservableObject {
    @Published private(set) var currentContext: TextContext?
    @Published private(set) var currentSuggestion: Suggestion?
    @Published private(set) var statusMessage: String = "Idle"
    @Published private(set) var lastLatencyMs: Int?

    private let contextProvider: TextContextProvider
    private var completionProvider: CompletionProvider
    private let presenter: SuggestionPresenter
    private let compatibilityCatalog: CompatibilityCatalog
    private let compatibilitySettings: CompatibilitySettingsStore
    private let privacyStore: PrivacySettingsStore
    private let shortcutLeakRepairInserter: ShortcutLeakRepairing?
    private let emojiService = EmojiSuggestionService()

    private var completionTask: Task<Void, Never>?
    private var timer: Timer?
    private var acceptanceState: AcceptanceState?
    private var completedAcceptAllState: CompletedAcceptAllState?
    private var lastSuggestionTriggerKeyAt: Date = .distantPast
    private var lastTextChangeTime: Date = .distantPast
    private var debounceTask: Task<Void, Never>?
    private let debounceInterval: TimeInterval = 0.25
    private let acceptanceEchoGraceInterval: TimeInterval = 3.0
    private let completedAcceptAllLeakGraceInterval: TimeInterval = 8.0
    private let suggestionTriggerKeyGraceInterval: TimeInterval = 1.2

    init(
        contextProvider: TextContextProvider,
        completionProvider: CompletionProvider,
        presenter: SuggestionPresenter,
        compatibilityCatalog: CompatibilityCatalog = CompatibilityCatalog(),
        compatibilitySettings: CompatibilitySettingsStore = CompatibilitySettingsStore(),
        privacyStore: PrivacySettingsStore = PrivacySettingsStore(),
        shortcutLeakRepairInserter: ShortcutLeakRepairing? = nil
    ) {
        self.contextProvider = contextProvider
        self.completionProvider = completionProvider
        self.presenter = presenter
        self.compatibilityCatalog = compatibilityCatalog
        self.compatibilitySettings = compatibilitySettings
        self.privacyStore = privacyStore
        self.shortcutLeakRepairInserter = shortcutLeakRepairInserter
    }

    func start() {
        stop()
        timer = Timer.scheduledTimer(withTimeInterval: 0.28, repeats: true) { [weak self] _ in
            Task { @MainActor in
                await self?.refresh()
            }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        completionTask?.cancel()
        completionTask = nil
        debounceTask?.cancel()
        debounceTask = nil
        acceptanceState = nil
        completedAcceptAllState = nil
        lastSuggestionTriggerKeyAt = .distantPast
        presenter.hide()
    }

    func hideSuggestion() {
        currentSuggestion = nil
        acceptanceState = nil
        completedAcceptAllState = nil
        presenter.hide()
    }

    func recordSuggestionTriggerKey() {
        lastSuggestionTriggerKeyAt = Date()
        GeometryDebug.log("suggestion-trigger-key kind=space")
    }

    func updateCompletionProvider(_ completionProvider: CompletionProvider, status: String) {
        completionTask?.cancel()
        debounceTask?.cancel()
        self.completionProvider = completionProvider
        currentSuggestion = nil
        acceptanceState = nil
        completedAcceptAllState = nil
        statusMessage = status
        presenter.hide()
    }

    func acceptNextWord(using inserter: TextInserter) async {
        guard var suggestion = currentSuggestion else {
            return
        }

        do {
            let previousContext = currentContext
            let previousSuggestion = suggestion
            guard let acceptedText = try await inserter.acceptNextWord(from: &suggestion) else {
                return
            }
            updateAcceptanceState(
                previousContext: previousContext,
                previousSuggestion: previousSuggestion,
                acceptedText: acceptedText
            )
            currentSuggestion = suggestion.isExhausted ? nil : suggestion

            if let context = currentContext, let currentSuggestion {
                presenter.update(currentSuggestion, for: context, mode: displayMode(for: context))
            } else {
                presenter.hide()
            }
        } catch {
            statusMessage = "Insertion failed"
        }
    }

    func acceptAll(using inserter: TextInserter) async {
        guard var suggestion = currentSuggestion else {
            return
        }

        do {
            let previousContext = currentContext
            let previousSuggestion = suggestion
            guard let acceptedText = try await inserter.acceptAll(from: &suggestion) else {
                return
            }
            updateAcceptanceState(
                previousContext: previousContext,
                previousSuggestion: previousSuggestion,
                acceptedText: acceptedText
            )
            completedAcceptAllState = acceptanceState.map {
                CompletedAcceptAllState(
                    focusedElementID: $0.focusedElementID,
                    focusedElementRect: $0.focusedElementRect,
                    app: $0.app,
                    domain: $0.domain,
                    baseTextBeforeCursor: $0.baseTextBeforeCursor,
                    expectedTextBeforeCursor: $0.expectedTextBeforeCursor,
                    lastAcceptedAt: $0.lastAcceptedAt
                )
            }
            GeometryDebug.log("completed-accept-all state=\(completedAcceptAllState == nil ? "nil" : "armed") acceptedLength=\((acceptedText as NSString).length)")
            acceptanceState = nil
            currentSuggestion = nil
            presenter.hide()
        } catch {
            statusMessage = "Insertion failed"
        }
    }

    private func refresh() async {
        do {
            let context = try await contextProvider.currentContext()

            if context.textBeforeCursor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                currentContext = context
                completionTask?.cancel()
                debounceTask?.cancel()
                hideSuggestion()
                statusMessage = "Waiting for text"
                GeometryDebug.log("suggestion-skip reason=empty-context app=\(context.app.displayName) bundle=\(context.app.bundleID)")
                return
            }

            if await repairLeakedShortcutIfNeeded(context) {
                return
            }

            if await repairCompletedAcceptAllLeakIfNeeded(context) {
                return
            }

            if handleAcceptedSuggestionSession(context) {
                return
            }

            if let suggestion = currentSuggestion,
               !suggestion.isExhausted,
               let previousContext = currentContext,
               isSameFocusedText(context, as: previousContext) {
                currentContext = context
                presenter.update(suggestion, for: context, mode: displayMode(for: context))
                return
            }

            if let suggestion = currentSuggestion,
               !suggestion.isExhausted,
               let previousContext = currentContext,
               isWebWhitespaceNormalizationDrift(context: context, previousContext: previousContext) {
                let presentationContext = context.replacingTextBeforeCursor(previousContext.textBeforeCursor)
                currentContext = presentationContext
                completionTask?.cancel()
                GeometryDebug.log("suggestion-keep reason=web-whitespace-normalization app=\(context.app.displayName) bundle=\(context.app.bundleID)")
                presenter.update(suggestion, for: presentationContext, mode: displayMode(for: presentationContext))
                return
            }

            // If we have a non-exhausted suggestion whose accepted prefix is
            // consistent with the current text, keep showing it.
            if let suggestion = currentSuggestion,
               !suggestion.isExhausted,
               let prevContext = currentContext,
               isTextConsistentWithAcceptedSuggestion(context: context, previousContext: prevContext, suggestion: suggestion) {
                currentContext = context
                presenter.update(suggestion, for: context, mode: displayMode(for: context))
                return
            }

            let previousObservedContext = currentContext
            guard shouldRequestSuggestion(for: context) else {
                return
            }

            guard shouldTriggerSuggestionAfterWhitespace(for: context, previousContext: previousObservedContext) else {
                GeometryDebug.log("suggestion-skip reason=awaiting-space-trigger app=\(context.app.displayName) bundle=\(context.app.bundleID)")
                currentContext = context
                completionTask?.cancel()
                debounceTask?.cancel()
                acceptanceState = nil
                currentSuggestion = nil
                statusMessage = "Waiting for space"
                presenter.hide()
                return
            }

            currentContext = context
            completionTask?.cancel()
            acceptanceState = nil
            completedAcceptAllState = nil

            if let emojiSuggestion = emojiService.suggestion(for: context.textBeforeCursor, contextID: context.id) {
                publish(emojiSuggestion, context: context)
                return
            }

            // Debounce: hide the current suggestion and wait for the user to
            // stop typing before requesting a new completion.
            hideSuggestion()
            lastTextChangeTime = Date()
            debounceTask?.cancel()
            debounceTask = Task { [weak self, debounceInterval] in
                try? await Task.sleep(nanoseconds: UInt64(debounceInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                await MainActor.run {
                    self?.requestCompletion(for: context)
                }
            }
        } catch {
            currentContext = nil
            currentSuggestion = nil
            statusMessage = (error as? LocalizedError)?.errorDescription ?? "No compatible text field"
            GeometryDebug.log("refresh-error status=\(statusMessage)")
            presenter.hide()
        }
    }

    private func requestCompletion(for context: TextContext) {
        lastSuggestionTriggerKeyAt = .distantPast
        GeometryDebug.log("completion-request app=\(context.app.displayName) bundle=\(context.app.bundleID) context=\(context.geometryDebugDescription)")
        completionTask?.cancel()
        completionTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            do {
                guard let self else { return }
                let suggestion = try await self.completionProvider.complete(context: context)
                await MainActor.run {
                    GeometryDebug.log("completion-success app=\(context.app.displayName) bundle=\(context.app.bundleID) visibleLength=\((suggestion.visibleText as NSString).length)")
                    self.publish(suggestion, context: context)
                }
            } catch {
                await MainActor.run {
                    GeometryDebug.log("completion-failed app=\(context.app.displayName) bundle=\(context.app.bundleID)")
                    self?.statusMessage = "Completion unavailable"
                    self?.hideSuggestion()
                }
            }
        }
    }

    private func repairLeakedShortcutIfNeeded(_ context: TextContext) async -> Bool {
        guard let shortcutLeakRepairInserter,
              let previousContext = currentContext,
              var suggestion = currentSuggestion,
              !suggestion.isExhausted,
              isSameInteractionTarget(context, as: previousContext),
              let leakedShortcut = leakedShortcut(
                in: context.textBeforeCursor,
                previousText: previousContext.textBeforeCursor,
                appBundleID: context.app.bundleID
              ) else {
            return false
        }
        let suffixScalars = leakedShortcut.suffix.unicodeScalars.map { String($0.value) }.joined(separator: ",")
        GeometryDebug.log("shortcut-repair detected suffixScalars=\(suffixScalars)")

        do {
            let previousSuggestion = suggestion
            let leakedLength = (leakedShortcut.suffix as NSString).length
            let acceptedText = try await shortcutLeakRepairInserter.replaceLeakedShortcutSuffix(
                length: leakedLength,
                withNextWordsFrom: &suggestion
            )

            guard let acceptedText else {
                return false
            }

            updateAcceptanceState(
                previousContext: previousContext,
                previousSuggestion: previousSuggestion,
                acceptedText: acceptedText
            )
            currentSuggestion = suggestion.isExhausted ? nil : suggestion

            let repairedContext = context.replacingTextBeforeCursor(
                previousContext.textBeforeCursor + acceptedText
            )
            currentContext = repairedContext
            completionTask?.cancel()
            statusMessage = leakedShortcut.action.statusMessage
            GeometryDebug.log("shortcut-repair action=\(leakedShortcut.action.debugName)")

            if let currentSuggestion {
                presenter.update(currentSuggestion, for: repairedContext, mode: displayMode(for: repairedContext))
            } else {
                presenter.hide()
            }
            return true
        } catch {
            statusMessage = "Insertion failed"
            return true
        }
    }

    private func repairCompletedAcceptAllLeakIfNeeded(_ context: TextContext) async -> Bool {
        guard let state = completedAcceptAllState else {
            return false
        }

        GeometryDebug.log("completed-accept-all check observedLength=\((context.textBeforeCursor as NSString).length) expectedLength=\((state.expectedTextBeforeCursor as NSString).length)")

        guard context.app == state.app,
              context.domain == state.domain else {
            GeometryDebug.log("completed-accept-all cleared reason=target-app-domain")
            completedAcceptAllState = nil
            return false
        }

        let sameFocusedElement = context.focusedElementID == state.focusedElementID
            || approximatelySameRect(context.focusedElementRect, state.focusedElementRect)
            || isSameGoogleDocsBrailleLineTarget(
                app: context.app,
                domain: context.domain,
                context.focusedElementRect,
                state.focusedElementRect
            )
        guard sameFocusedElement else {
            GeometryDebug.log("completed-accept-all cleared reason=focused-target")
            completedAcceptAllState = nil
            return false
        }

        if completedAcceptAllTextMatchesExpected(context.textBeforeCursor, state: state) {
            currentContext = context
            GeometryDebug.log("completed-accept-all settled")
            if Date().timeIntervalSince(state.lastAcceptedAt) > completedAcceptAllLeakGraceInterval {
                completedAcceptAllState = nil
            }
            return true
        }

        let isPotentialDelayedEcho = isCompletedAcceptAllPotentialDelayedEcho(
            context.textBeforeCursor,
            state: state
        )
        if isPotentialDelayedEcho,
           Date().timeIntervalSince(state.lastAcceptedAt) <= completedAcceptAllLeakGraceInterval {
            currentContext = context
            return true
        }

        completedAcceptAllState = nil
        GeometryDebug.log("completed-accept-all cleared reason=diverged")
        return false
    }

    private func completedAcceptAllTextMatchesExpected(
        _ observedText: String,
        state: CompletedAcceptAllState
    ) -> Bool {
        textMatchesExpectedOrOnlyAddsTrailingWhitespace(
            observedText,
            expectedText: state.expectedTextBeforeCursor
        ) || textMatchesExpectedOrOnlyAddsTrailingWhitespace(
            normalizedAcceptanceWhitespace(in: observedText),
            expectedText: normalizedAcceptanceWhitespace(in: state.expectedTextBeforeCursor)
        )
    }

    private func textMatchesExpectedOrOnlyAddsTrailingWhitespace(
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

    private func isCompletedAcceptAllPotentialDelayedEcho(
        _ observedText: String,
        state: CompletedAcceptAllState
    ) -> Bool {
        if state.expectedTextBeforeCursor.hasPrefix(observedText),
           observedText.hasPrefix(state.baseTextBeforeCursor) {
            return true
        }

        let normalizedObservedText = normalizedAcceptanceWhitespace(in: observedText)
        let normalizedExpectedText = normalizedAcceptanceWhitespace(in: state.expectedTextBeforeCursor)
        let normalizedBaseText = normalizedAcceptanceWhitespace(in: state.baseTextBeforeCursor)
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

    private func shouldRequestSuggestion(for context: TextContext) -> Bool {
        let decision = compatibilityCatalog.decision(
            bundleID: context.app.bundleID,
            domain: context.domain,
            userEnabledOverrides: compatibilitySettings.loadOverrides()
        )

        guard decision.enabled, decision.mode != .disabled, decision.profile.status != .unsupported else {
            GeometryDebug.log("suggestion-skip reason=compatibility app=\(context.app.displayName) bundle=\(context.app.bundleID) enabled=\(decision.enabled) mode=\(decision.mode.rawValue) status=\(decision.profile.status.rawValue)")
            statusMessage = decision.profile.notes.isEmpty ? "Disabled for \(context.app.displayName)" : decision.profile.notes
            hideSuggestion()
            return false
        }

        let trimmed = context.textBeforeCursor.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            GeometryDebug.log("suggestion-skip reason=empty-context app=\(context.app.displayName) bundle=\(context.app.bundleID)")
            hideSuggestion()
            return false
        }

        guard !TextContinuationHeuristics.shouldSuppressAutocomplete(after: context.textBeforeCursor) else {
            GeometryDebug.log("suggestion-skip reason=sentence-complete app=\(context.app.displayName) bundle=\(context.app.bundleID)")
            statusMessage = "Sentence complete"
            hideSuggestion()
            return false
        }

        if let previousContext = currentContext,
           previousContext.textBeforeCursor == context.textBeforeCursor,
           previousContext.app == context.app,
           previousContext.domain == context.domain {
            GeometryDebug.log("suggestion-skip reason=unchanged-context app=\(context.app.displayName) bundle=\(context.app.bundleID)")
            return false
        }

        GeometryDebug.log("suggestion-eligible app=\(context.app.displayName) bundle=\(context.app.bundleID)")
        return true
    }

    private func shouldTriggerSuggestionAfterWhitespace(
        for context: TextContext,
        previousContext: TextContext?
    ) -> Bool {
        guard textEndsWithSuggestionTriggerWhitespace(context.textBeforeCursor) else {
            return false
        }

        if let previousContext,
           isSameInteractionTarget(context, as: previousContext),
           previousContext.textBeforeCursor != context.textBeforeCursor {
            return true
        }

        let hasRecentTriggerKey = Date().timeIntervalSince(lastSuggestionTriggerKeyAt) <= suggestionTriggerKeyGraceInterval
        if hasRecentTriggerKey {
            GeometryDebug.log("suggestion-trigger reason=recent-space-key app=\(context.app.displayName) bundle=\(context.app.bundleID)")
            return true
        }

        return false
    }

    private func textEndsWithSuggestionTriggerWhitespace(_ text: String) -> Bool {
        guard let lastScalar = text.unicodeScalars.last else {
            return false
        }
        return CharacterSet.whitespacesAndNewlines.contains(lastScalar)
    }

    private func isWebWhitespaceNormalizationDrift(context: TextContext, previousContext: TextContext) -> Bool {
        guard isWebLikeApp(context.app.bundleID),
              isSameInteractionTarget(context, as: previousContext),
              textEndsWithSuggestionTriggerWhitespace(previousContext.textBeforeCursor),
              droppingTrailingWhitespace(from: previousContext.textBeforeCursor) == context.textBeforeCursor else {
            return false
        }

        return true
    }

    private func droppingTrailingWhitespace(from text: String) -> String {
        var scalars = text.unicodeScalars
        while let last = scalars.last, CharacterSet.whitespacesAndNewlines.contains(last) {
            scalars.removeLast()
        }
        return String(scalars)
    }

    private func isWebLikeApp(_ bundleID: String) -> Bool {
        [
            "com.openai.codex",
            "com.google.Chrome",
            "com.brave.Browser",
            "com.microsoft.edgemac",
            "company.thebrowser.Browser",
            "company.thebrowser.dia",
            "com.todesktop.230313mzl4w4u92"
        ].contains(bundleID)
    }

    private func isSameFocusedText(_ context: TextContext, as previousContext: TextContext) -> Bool {
        previousContext.textBeforeCursor == context.textBeforeCursor
            && isSameInteractionTarget(context, as: previousContext)
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

    private func publish(_ suggestion: Suggestion, context: TextContext) {
        let suggestion = normalizedSuggestion(suggestion, for: context)
        guard !suggestion.visibleText.isEmpty else {
            hideSuggestion()
            return
        }

        acceptanceState = nil
        completedAcceptAllState = nil
        currentSuggestion = suggestion
        lastLatencyMs = suggestion.latencyMs
        statusMessage = "Suggesting in \(context.app.displayName)"

        let mode = displayMode(for: context)
        presenter.show(suggestion, for: context, mode: mode)

        let privacy = privacyStore.load()
        if privacy.allowsCollection(appBundleID: context.app.bundleID, domain: context.domain) {
            statusMessage = "Suggesting in \(context.app.displayName); collection enabled"
        }
    }

    private func normalizedSuggestion(_ suggestion: Suggestion, for context: TextContext) -> Suggestion {
        guard textEndsWithSuggestionTriggerWhitespace(context.textBeforeCursor) else {
            return suggestion
        }

        var normalized = suggestion
        normalized.visibleText = droppingLeadingWhitespace(from: normalized.visibleText)
        normalized.remainingText = droppingLeadingWhitespace(from: normalized.remainingText)
        return normalized
    }

    private func droppingLeadingWhitespace(from text: String) -> String {
        let firstNonWhitespace = text.unicodeScalars.firstIndex {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        guard let firstNonWhitespace else {
            return ""
        }
        return String(text.unicodeScalars[firstNonWhitespace...])
    }

    private func displayMode(for context: TextContext) -> SuggestionDisplayMode {
        compatibilityCatalog.decision(
            bundleID: context.app.bundleID,
            domain: context.domain,
            userEnabledOverrides: compatibilitySettings.loadOverrides()
        ).mode
    }

    private func updateAcceptanceState(
        previousContext: TextContext?,
        previousSuggestion: Suggestion,
        acceptedText: String
    ) {
        guard let previousContext else {
            return
        }

        let baseText = acceptanceState?.baseTextBeforeCursor ?? previousContext.textBeforeCursor
        let acceptedPrefix = (acceptanceState?.acceptedPrefix ?? previousSuggestion.acceptedPrefix) + acceptedText
        let expectedText = baseText + acceptedPrefix

        acceptanceState = AcceptanceState(
            focusedElementID: previousContext.focusedElementID,
            focusedElementRect: previousContext.focusedElementRect,
            app: previousContext.app,
            domain: previousContext.domain,
            baseTextBeforeCursor: baseText,
            acceptedPrefix: acceptedPrefix,
            expectedTextBeforeCursor: expectedText,
            lastAcceptedAt: Date()
        )
    }

    private func isTextConsistentWithAcceptedSuggestion(
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

        let baseText = acceptanceState?.baseTextBeforeCursor ?? previousContext.textBeforeCursor
        let expectedText = baseText + suggestion.acceptedPrefix

        if context.textBeforeCursor == expectedText {
            return true
        }

        if context.textBeforeCursor.hasPrefix(expectedText) {
            let suffix = context.textBeforeCursor.dropFirst(expectedText.count)
            return suffix.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
        }

        return false
    }

    private func handleAcceptedSuggestionSession(_ context: TextContext) -> Bool {
        guard let state = acceptanceState else {
            return false
        }

        guard context.app == state.app,
              context.domain == state.domain else {
            acceptanceState = nil
            currentSuggestion = nil
            presenter.hide()
            return false
        }

        let sameFocusedElement = context.focusedElementID == state.focusedElementID
            || approximatelySameRect(context.focusedElementRect, state.focusedElementRect)
            || isSameGoogleDocsBrailleLineTarget(
                app: context.app,
                domain: context.domain,
                context.focusedElementRect,
                state.focusedElementRect
            )
        guard sameFocusedElement else {
            acceptanceState = nil
            currentSuggestion = nil
            presenter.hide()
            return false
        }

        switch acceptanceRelation(for: context.textBeforeCursor, state: state) {
        case .settled, .pendingEcho:
            currentContext = context
            completionTask?.cancel()

            if let currentSuggestion, !currentSuggestion.isExhausted {
                presenter.update(currentSuggestion, for: context, mode: displayMode(for: context))
            } else {
                presenter.hide()
            }

            statusMessage = "Continuing accepted suggestion"
            return true
        case .trailingWhitespace:
            currentContext = context
            completionTask?.cancel()
            statusMessage = "Ignoring accepted suggestion echo"
            return true
        case .diverged:
            acceptanceState = nil
            currentSuggestion = nil
            presenter.hide()
            return false
        }
    }

    private func acceptanceRelation(for observedText: String, state: AcceptanceState) -> AcceptanceRelation {
        if let relation = exactAcceptanceRelation(
            observedText: observedText,
            expectedText: state.expectedTextBeforeCursor,
            baseText: state.baseTextBeforeCursor,
            lastAcceptedAt: state.lastAcceptedAt
        ) {
            return relation
        }

        let normalizedObservedText = normalizedAcceptanceWhitespace(in: observedText)
        let normalizedExpectedText = normalizedAcceptanceWhitespace(in: state.expectedTextBeforeCursor)
        let normalizedBaseText = normalizedAcceptanceWhitespace(in: state.baseTextBeforeCursor)
        if normalizedObservedText != observedText
            || normalizedExpectedText != state.expectedTextBeforeCursor
            || normalizedBaseText != state.baseTextBeforeCursor,
            let relation = exactAcceptanceRelation(
                observedText: normalizedObservedText,
                expectedText: normalizedExpectedText,
                baseText: normalizedBaseText,
                lastAcceptedAt: state.lastAcceptedAt
            ) {
            return relation
        }

        return .diverged
    }

    private func exactAcceptanceRelation(
        observedText: String,
        expectedText: String,
        baseText: String,
        lastAcceptedAt: Date
    ) -> AcceptanceRelation? {
        if observedText == expectedText {
            return .settled
        }

        if observedText.hasPrefix(expectedText) {
            let suffix = observedText.dropFirst(expectedText.count)
            return suffix.unicodeScalars.allSatisfy { CharacterSet.whitespacesAndNewlines.contains($0) }
                ? .trailingWhitespace
                : .diverged
        }

        let isPotentialDelayedEcho = expectedText.hasPrefix(observedText)
            && observedText.hasPrefix(baseText)
        if isPotentialDelayedEcho,
           Date().timeIntervalSince(lastAcceptedAt) <= acceptanceEchoGraceInterval {
            return .pendingEcho
        }

        return nil
    }

    private func normalizedAcceptanceWhitespace(in text: String) -> String {
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

private struct AcceptanceState {
    let focusedElementID: String
    let focusedElementRect: CGRect?
    let app: AppIdentity
    let domain: String?
    let baseTextBeforeCursor: String
    let acceptedPrefix: String
    let expectedTextBeforeCursor: String
    let lastAcceptedAt: Date
}

private struct CompletedAcceptAllState {
    let focusedElementID: String
    let focusedElementRect: CGRect?
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

private enum AcceptanceRelation {
    case settled
    case pendingEcho
    case trailingWhitespace
    case diverged
}

private extension TextContext {
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
            languageHint: languageHint,
            captureSources: captureSources,
            createdAt: createdAt
        )
    }
}
