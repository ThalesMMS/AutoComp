import AutoCompCore
import CoreGraphics
import Foundation

@MainActor
final class SuggestionEngine: ObservableObject {
    @Published private(set) var currentContext: TextContext?
    @Published private(set) var currentSuggestion: Suggestion?
    @Published private(set) var statusMessage: String = "Idle"
    @Published private(set) var lastLatencyMs: Int?
    @Published private(set) var diagnostics = SuggestionDiagnostics()

    private let focusProvider: TextContextProvider
    private var generationProvider: CompletionProvider
    private let visualContextProvider: VisualContextProvider?
    private let presenter: SuggestionPresenter
    private let inputController: SuggestionInputStateTracking
    private let compatibilityCatalog: CompatibilityCatalog
    private let compatibilitySettings: CompatibilitySettingsStore
    private let privacyStore: PrivacySettingsStore
    private let eligibilityEvaluator: SuggestionEligibilityEvaluator
    private let publicationController: SuggestionPublicationController
    private let acceptanceSessionController: AcceptanceSessionController
    private let shortcutLeakRepairInserter: ShortcutLeakRepairing?
    private let emojiService = EmojiSuggestionService()
    private let workController = SuggestionWorkController()
    private let contextGenerationTracker = ContextGenerationTracker()

    private var timer: Timer?
    private var lastTextChangeTime: Date = .distantPast
    private let debounceInterval: TimeInterval = 0.25
    private var transientFocusFailureStartedAt: Date?
    private let transientFocusFailureGraceInterval: TimeInterval = 1.5

    init(
        contextProvider: TextContextProvider,
        completionProvider: CompletionProvider,
        visualContextProvider: VisualContextProvider? = nil,
        presenter: SuggestionPresenter,
        compatibilityCatalog: CompatibilityCatalog = CompatibilityCatalog(),
        compatibilitySettings: CompatibilitySettingsStore = CompatibilitySettingsStore(),
        privacyStore: PrivacySettingsStore = PrivacySettingsStore(),
        eligibilityEvaluator: SuggestionEligibilityEvaluator = SuggestionEligibilityEvaluator(),
        publicationController: SuggestionPublicationController? = nil,
        acceptanceSessionController: AcceptanceSessionController = AcceptanceSessionController(),
        inputController: SuggestionInputStateTracking = SemanticInputController(),
        shortcutLeakRepairInserter: ShortcutLeakRepairing? = nil
    ) {
        self.focusProvider = contextProvider
        self.generationProvider = completionProvider
        self.visualContextProvider = visualContextProvider
        self.presenter = presenter
        self.inputController = inputController
        self.compatibilityCatalog = compatibilityCatalog
        self.compatibilitySettings = compatibilitySettings
        self.privacyStore = privacyStore
        self.eligibilityEvaluator = eligibilityEvaluator
        self.publicationController = publicationController ?? SuggestionPublicationController(presenter: presenter)
        self.acceptanceSessionController = acceptanceSessionController
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
        workController.cancelAll()
        acceptanceSessionController.clearAll()
        inputController.reset()
        presenter.hide()
    }

    func hideSuggestion() {
        currentSuggestion = nil
        acceptanceSessionController.clearAll()
        presenter.hide()
    }

    func recordSuggestionTriggerKey(_ event: CapturedInputEvent) {
        inputController.record(event)
    }

    func updateCompletionProvider(_ completionProvider: CompletionProvider, status: String) {
        workController.cancelAll()
        self.generationProvider = completionProvider
        currentSuggestion = nil
        acceptanceSessionController.clearAll()
        inputController.reset()
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
            acceptanceSessionController.recordAcceptance(
                previousContext: previousContext,
                previousSuggestion: previousSuggestion,
                updatedSuggestion: suggestion,
                acceptedText: acceptedText
            )
            currentSuggestion = suggestion.isExhausted ? nil : suggestion

            if let context = currentContext, let currentSuggestion {
                let presentationContext = predictedPresentationContext(
                    afterAccepting: acceptedText,
                    from: context
                ) ?? context
                presenter.update(
                    currentSuggestion,
                    for: presentationContext,
                    mode: displayMode(for: presentationContext)
                )
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
            acceptanceSessionController.recordAcceptance(
                previousContext: previousContext,
                previousSuggestion: previousSuggestion,
                updatedSuggestion: suggestion,
                acceptedText: acceptedText
            )
            let acceptAllStateArmed = acceptanceSessionController.armCompletedAcceptAll()
            GeometryDebug.log("completed-accept-all state=\(acceptAllStateArmed ? "armed" : "nil") acceptedLength=\((acceptedText as NSString).length)")
            currentSuggestion = nil
            presenter.hide()
        } catch {
            statusMessage = "Insertion failed"
        }
    }

    private func refresh() async {
        do {
            let context = try await focusProvider.currentContext()
            transientFocusFailureStartedAt = nil
            diagnostics.recordFocus(context: context)

            if context.textBeforeCursor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let decision = eligibilityDecision(for: context, previousObservedContext: currentContext)
                diagnostics.recordEligibility(decision)
                logEligibilityDecision(decision)
                applyIneligibleDecision(decision, context: context)
                return
            }

            if await repairLeakedShortcutIfNeeded(context) {
                return
            }

            if repairCompletedAcceptAllLeakIfNeeded(context) {
                return
            }

            if let suggestion = currentSuggestion,
               !suggestion.isExhausted,
               let previousContext = currentContext,
               isWebWhitespaceNormalizationDrift(context: context, previousContext: previousContext) {
                let presentationContext = context.replacingTextBeforeCursor(previousContext.textBeforeCursor)
                currentContext = presentationContext
                workController.cancelAll()
                GeometryDebug.log("suggestion-keep reason=web-whitespace-normalization app=\(context.app.displayName) bundle=\(context.app.bundleID)")
                presenter.update(suggestion, for: presentationContext, mode: displayMode(for: presentationContext))
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
            let eligibilityDecision = eligibilityDecision(
                for: context,
                previousObservedContext: previousObservedContext
            )
            diagnostics.recordEligibility(eligibilityDecision)
            logEligibilityDecision(eligibilityDecision)
            guard eligibilityDecision.isEligible else {
                applyIneligibleDecision(eligibilityDecision, context: context)
                return
            }

            currentContext = context
            workController.cancelAll()
            acceptanceSessionController.clearAll()

            if let emojiSuggestion = emojiService.suggestion(for: context.textBeforeCursor, contextID: context.id) {
                publish(emojiSuggestion, context: context)
                return
            }

            // Debounce: hide the current suggestion and wait for the user to
            // stop typing before requesting a new completion.
            hideSuggestion()
            lastTextChangeTime = Date()
            workController.replaceDebouncedWork { [weak self, debounceInterval] workID in
                try? await Task.sleep(nanoseconds: UInt64(debounceInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                guard let engine = self else { return }
                await MainActor.run {
                    guard engine.workController.isCurrent(workID) else {
                        return
                    }
                    engine.requestCompletion(for: context)
                }
            }
        } catch {
            if preserveSuggestionAcrossTransientFocusFailure(error) {
                return
            }

            currentContext = nil
            currentSuggestion = nil
            statusMessage = (error as? LocalizedError)?.errorDescription ?? "No compatible text field"
            GeometryDebug.log("refresh-error status=\(statusMessage)")
            presenter.hide()
        }
    }

    private func eligibilityDecision(
        for context: TextContext,
        previousObservedContext: TextContext?
    ) -> SuggestionEligibilityDecision {
        eligibilityEvaluator.evaluate(
            context: context,
            previousContext: previousObservedContext,
            compatibilityDecision: compatibilityCatalog.decision(
                bundleID: context.app.bundleID,
                domain: context.domain,
                userEnabledOverrides: compatibilitySettings.loadOverrides()
            ),
            lastSuggestionTriggerKeyAt: inputController.lastSuggestionTriggerKeyAt
        )
    }

    private func applyIneligibleDecision(
        _ decision: SuggestionEligibilityDecision,
        context: TextContext
    ) {
        if let statusMessage = decision.statusMessage {
            self.statusMessage = statusMessage
        }

        switch decision.skipReason {
        case .emptyContext:
            currentContext = context
            workController.cancelAll()
            hideSuggestion()
        case .compatibility, .sentenceComplete:
            hideSuggestion()
        case .unchangedContext:
            break
        case .awaitingSpaceTrigger:
            currentContext = context
            workController.cancelAll()
            acceptanceSessionController.clearAcceptance()
            currentSuggestion = nil
            presenter.hide()
        case nil:
            break
        }
    }

    private func logEligibilityDecision(_ decision: SuggestionEligibilityDecision) {
        decision.logs.forEach(logEligibility)
    }

    private func logEligibility(_ log: SuggestionEligibilityLogData) {
        switch log.kind {
        case .eligible:
            GeometryDebug.log("suggestion-eligible app=\(log.appDisplayName) bundle=\(log.bundleID)")
        case .skip(let reason):
            switch reason {
            case .compatibility:
                let enabled = log.compatibilityEnabled.map(String.init) ?? "nil"
                GeometryDebug.log("suggestion-skip reason=\(reason.rawValue) app=\(log.appDisplayName) bundle=\(log.bundleID) enabled=\(enabled) mode=\(log.displayMode?.rawValue ?? "nil") status=\(log.compatibilityStatus?.rawValue ?? "nil")")
            default:
                GeometryDebug.log("suggestion-skip reason=\(reason.rawValue) app=\(log.appDisplayName) bundle=\(log.bundleID)")
            }
        case .trigger(let reason):
            GeometryDebug.log("suggestion-trigger reason=\(reason.rawValue) app=\(log.appDisplayName) bundle=\(log.bundleID)")
        }
    }

    private func requestCompletion(for context: TextContext) {
        inputController.clearSuggestionTrigger()
        diagnostics.recordBackendRequest()
        let requestedSignature = contextGenerationTracker.signature(for: context)
        GeometryDebug.log("completion-request app=\(context.app.displayName) bundle=\(context.app.bundleID) context=\(context.geometryDebugDescription)")
        workController.replaceGenerationWork { [weak self] workID in
            guard !Task.isCancelled else { return }
            guard let engine = self else { return }
            do {
                let privacySettings = engine.privacyStore.load()
                let visualContext = await engine.visualContextProvider?.currentVisualContext()
                let suggestion = try await engine.complete(
                    context: context,
                    privacySettings: privacySettings,
                    visualContext: visualContext
                )
                let liveContext: TextContext
                do {
                    liveContext = try await engine.focusProvider.currentContext()
                } catch {
                    await MainActor.run {
                        guard engine.workController.isCurrent(workID) else {
                            return
                        }
                        GeometryDebug.log("completion-discarded reason=missing-live-context app=\(context.app.displayName) bundle=\(context.app.bundleID)")
                        engine.diagnostics.recordStaleDiscard(reason: "missing-live-context")
                        engine.hideSuggestion()
                    }
                    return
                }
                await MainActor.run {
                    guard engine.workController.isCurrent(workID) else {
                        GeometryDebug.log("completion-discarded reason=stale-work app=\(context.app.displayName) bundle=\(context.app.bundleID)")
                        engine.diagnostics.recordStaleDiscard(reason: "stale-work")
                        return
                    }

                    guard engine.contextGenerationTracker.matches(liveContext, signature: requestedSignature) else {
                        GeometryDebug.log("completion-discarded reason=stale-context app=\(context.app.displayName) bundle=\(context.app.bundleID)")
                        engine.diagnostics.recordStaleDiscard(reason: "stale-context")
                        return
                    }

                    GeometryDebug.log("completion-success app=\(liveContext.app.displayName) bundle=\(liveContext.app.bundleID) visibleLength=\((suggestion.visibleText as NSString).length)")
                    engine.publish(suggestion, context: liveContext)
                }
            } catch {
                await MainActor.run {
                    guard engine.workController.isCurrent(workID) else {
                        return
                    }
                    GeometryDebug.log("completion-failed app=\(context.app.displayName) bundle=\(context.app.bundleID)")
                    engine.diagnostics.recordBackendFailure(error)
                    engine.statusMessage = SuggestionDiagnostics.message(for: error)
                    engine.hideSuggestion()
                }
            }
        }
    }

    private func complete(
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?
    ) async throws -> Suggestion {
        if let provider = generationProvider as? VisualContextAwareCompletionProvider {
            return try await provider.complete(
                context: context,
                privacySettings: privacySettings,
                visualContext: visualContext
            )
        }
        return try await generationProvider.complete(context: context)
    }

    private func repairLeakedShortcutIfNeeded(_ context: TextContext) async -> Bool {
        guard let result = await acceptanceSessionController.repairLeakedShortcutIfNeeded(
            context: context,
            previousContext: currentContext,
            currentSuggestion: currentSuggestion,
            repairInserter: shortcutLeakRepairInserter
        ) else {
            return false
        }

        switch result {
        case .repaired(let repairedContext, let updatedSuggestion, let statusMessage):
            currentSuggestion = updatedSuggestion
            currentContext = repairedContext
            workController.cancelAll()
            self.statusMessage = statusMessage

            if let currentSuggestion {
                presenter.update(currentSuggestion, for: repairedContext, mode: displayMode(for: repairedContext))
            } else {
                presenter.hide()
            }
        case .failed(let statusMessage):
            self.statusMessage = statusMessage
        }
        return true
    }

    private func repairCompletedAcceptAllLeakIfNeeded(_ context: TextContext) -> Bool {
        switch acceptanceSessionController.repairCompletedAcceptAllLeakIfNeeded(context: context) {
        case .notActive, .cleared:
            return false
        case .handled:
            currentContext = context
            return true
        }
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
            "com.apple.Safari",
            "com.google.Chrome",
            "com.brave.Browser",
            "com.microsoft.edgemac",
            "company.thebrowser.Browser",
            "company.thebrowser.dia",
            "com.todesktop.230313mzl4w4u92"
        ].contains(bundleID)
    }

    private func preserveSuggestionAcrossTransientFocusFailure(_ error: Error, now: Date = Date()) -> Bool {
        guard isTransientFocusReadError(error),
              let suggestion = currentSuggestion,
              !suggestion.isExhausted,
              let context = currentContext,
              isGoogleDocsContext(context) else {
            transientFocusFailureStartedAt = nil
            return false
        }

        let startedAt = transientFocusFailureStartedAt ?? now
        transientFocusFailureStartedAt = startedAt
        guard now.timeIntervalSince(startedAt) <= transientFocusFailureGraceInterval else {
            transientFocusFailureStartedAt = nil
            return false
        }

        GeometryDebug.log("suggestion-keep reason=transient-focus-read-failure app=\(context.app.displayName) bundle=\(context.app.bundleID)")
        presenter.update(suggestion, for: context, mode: displayMode(for: context))
        return true
    }

    private func isTransientFocusReadError(_ error: Error) -> Bool {
        guard let contextError = error as? AXTextContextError else {
            return false
        }

        switch contextError {
        case .noReadableText, .noFocusedElement:
            return true
        case .accessibilityNotTrusted, .noFrontmostApplication, .secureOrUnsupportedField:
            return false
        }
    }

    private func isGoogleDocsContext(_ context: TextContext) -> Bool {
        isWebLikeApp(context.app.bundleID)
            && context.domain?.contains("docs.google.com") == true
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

        if FocusIdentity(context: previousContext).matches(FocusIdentity(context: context)) {
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
        let mode = displayMode(for: context)
        let privacy = privacyStore.load()
        let collectionAllowed = privacy.allowsCollection(appBundleID: context.app.bundleID, domain: context.domain)
        let result = publicationController.publish(
            suggestion,
            context: context,
            displayMode: mode,
            collectionAllowed: collectionAllowed
        )
        logPublicationResult(result)

        switch result.outcome {
        case .published(let suggestion):
            diagnostics.recordBackendSuccess(
                rawText: suggestion.rawText,
                normalizedText: suggestion.visibleText,
                collectionAllowed: collectionAllowed
            )
            currentSuggestion = suggestion
            acceptanceSessionController.recordPublication(context: context, suggestion: suggestion)
            lastLatencyMs = result.lastLatencyMs
            if let statusMessage = result.statusMessage {
                self.statusMessage = statusMessage
            }
        case .rejected:
            acceptanceSessionController.clearAll()
            currentSuggestion = nil
        }
    }

    private func displayMode(for context: TextContext) -> SuggestionDisplayMode {
        compatibilityCatalog.decision(
            bundleID: context.app.bundleID,
            domain: context.domain,
            userEnabledOverrides: compatibilitySettings.loadOverrides()
        ).mode
    }

    private func logPublicationResult(_ result: SuggestionPublicationResult) {
        result.logs.forEach { log in
            switch log.kind {
            case .published:
                GeometryDebug.log("suggestion-publication result=published app=\(log.appDisplayName) bundle=\(log.bundleID) mode=\(log.displayMode.rawValue) visibleLength=\(log.visibleLength)")
            case .rejected(let reason):
                GeometryDebug.log("suggestion-publication result=rejected reason=\(reason.rawValue) app=\(log.appDisplayName) bundle=\(log.bundleID) mode=\(log.displayMode.rawValue)")
            }
        }
    }

    private func predictedPresentationContext(
        afterAccepting acceptedText: String,
        from context: TextContext
    ) -> TextContext? {
        guard let predictedContext = CaretPrediction.predictedContext(
            afterAccepting: acceptedText,
            from: context
        ) else {
            return nil
        }

        GeometryDebug.log("caret-prediction acceptedLength=\((acceptedText as NSString).length) oldCaretRect=\(String(describing: context.caretRect)) predictedCaretRect=\(String(describing: predictedContext.caretRect))")
        return predictedContext
    }

    private func isTextConsistentWithAcceptedSuggestion(
        context: TextContext,
        previousContext: TextContext,
        suggestion: Suggestion
    ) -> Bool {
        acceptanceSessionController.isTextConsistentWithAcceptedSuggestion(
            context: context,
            previousContext: previousContext,
            suggestion: suggestion
        )
    }

    private func handleAcceptedSuggestionSession(_ context: TextContext) -> Bool {
        let result = acceptanceSessionController.handleAcceptedSuggestionSession(
            context: context,
            currentSuggestion: currentSuggestion
        )

        switch result {
        case .notActive:
            return false
        case .handled(let handledResult):
            currentContext = context
            workController.cancelAll()
            currentSuggestion = handledResult.currentSuggestion

            if let currentSuggestion {
                presenter.update(currentSuggestion, for: context, mode: displayMode(for: context))
            } else {
                presenter.hide()
            }

            statusMessage = handledResult.statusMessage
            return true
        case .cleared:
            currentSuggestion = nil
            presenter.hide()
            return false
        }
    }
}
