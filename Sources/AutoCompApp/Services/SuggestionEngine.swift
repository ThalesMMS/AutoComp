import AutoCompCore
import CoreGraphics
import Foundation

private enum CompletionInvocation {
    case automatic
    case manual

    var debugName: String {
        switch self {
        case .automatic:
            return "automatic"
        case .manual:
            return "manual"
        }
    }
}

enum CompletionProviderSwitchReason: String, Equatable, Sendable {
    case backendSwitch = "backend-switch"
    case runtimeModelSwitch = "runtime-model-switch"
}

private enum AcceptanceCommandAction {
    case nextWord
    case fullSuggestion

    var debugName: String {
        switch self {
        case .nextWord:
            return "next-word"
        case .fullSuggestion:
            return "full-suggestion"
        }
    }
}

private struct RiskyHostAcceptanceBlock: Equatable {
    let reason: String
    let statusMessage: String
    let diagnosticAction: String
}

private struct CompletionLatencySeed: Sendable {
    var startedAt: ContinuousClock.Instant
    var axCaptureMs: Int?
    var geometryMs: Int?
    var debounceMs: Int?
}

enum SuggestionAcceptanceCommandOutcome: Equatable {
    case accepted
    case passedThrough
    case failed
}

private enum SuggestionRefreshSource: Equatable, Sendable {
    case poll
    case inputEvent(CapturedInputEvent)

    var debugName: String {
        switch self {
        case .poll:
            return "poll"
        case .inputEvent(let event):
            return "input-\(event.eventKind.rawValue)-\(event.debugName)"
        }
    }

    var shouldStopAfterAppSwitchClear: Bool {
        self == .poll
    }
}

@MainActor
final class SuggestionEngine: ObservableObject {
    @Published private(set) var currentContext: TextContext?
    @Published private(set) var currentSuggestion: Suggestion?
    @Published private(set) var statusMessage: String = "Idle"
    @Published private(set) var lastLatencyMs: Int?
    @Published private(set) var diagnostics = SuggestionDiagnostics()
    @Published private(set) var isAutocompleteEnabled = true
    @Published private(set) var isMultiSuggestionEnabled: Bool
    @Published private(set) var backendStatusSummary: BackendStatusSummary = .connected

    private let focusProvider: TextContextProvider
    private var generationProvider: CompletionProvider
    private var backendHealthMonitor: BackendHealthMonitor
    private let visualContextProvider: VisualContextProvider?
    private let clipboardContextProvider: ClipboardContextProvider?
    private let presenter: SuggestionPresenter
    private let inputController: SuggestionInputStateTracking
    private let compatibilityCatalog: CompatibilityCatalog
    private let compatibilitySettings: CompatibilitySettingsStore
    private let privacyStore: PrivacySettingsStore
    private let productivityMetrics: ProductivityMetricsRecording?
    private let eligibilityEvaluator: SuggestionEligibilityEvaluator
    private let inputMethodStateProvider: @Sendable () -> InputMethodState
    private let keystrokeBufferFallback: KeystrokeBufferFallback?
    private let publicationController: SuggestionPublicationController
    private let acceptanceSessionController: AcceptanceSessionController
    private let acceptanceController: SuggestionAcceptanceController
    private let shortcutLeakRepairInserter: ShortcutLeakRepairing?
    private let emojiService = EmojiSuggestionService()
    private let lifecycleController = SuggestionLifecycleController()
    private let predictionController = SuggestionPredictionController()
    private let diagnosticsController = SuggestionDiagnosticsController()
    private let contextGenerationTracker = ContextGenerationTracker()
    private let suggestionDebugLogger: SuggestionDebugLogger?
    private let debugOptionsProvider: @MainActor () -> AutoCompDebugOptions

    private var providerLifecycleGeneration = 0
    private var dismissedContext: TextContext?
    private var postAcceptanceRefreshTask: Task<Void, Never>?
    private var transientFocusFailureStartedAt: Date?
    private let transientFocusFailureGraceInterval: TimeInterval = 1.5
    private let postAcceptanceRefreshDelayNanoseconds: UInt64 = 150_000_000

    init(
        contextProvider: TextContextProvider,
        completionProvider: CompletionProvider,
        backendHealthMonitor: BackendHealthMonitor = BackendHealthMonitor(),
        visualContextProvider: VisualContextProvider? = nil,
        clipboardContextProvider: ClipboardContextProvider? = nil,
        presenter: SuggestionPresenter,
        compatibilityCatalog: CompatibilityCatalog = CompatibilityCatalog(),
        compatibilitySettings: CompatibilitySettingsStore = CompatibilitySettingsStore(),
        privacyStore: PrivacySettingsStore = PrivacySettingsStore(),
        productivityMetrics: ProductivityMetricsRecording? = nil,
        multiSuggestionEnabled: Bool = CompletionBackendSettings.defaultMultiSuggestionEnabled,
        eligibilityEvaluator: SuggestionEligibilityEvaluator = SuggestionEligibilityEvaluator(),
        inputMethodStateProvider: @escaping @Sendable () -> InputMethodState = { .asciiCompatible },
        keystrokeBufferFallback: KeystrokeBufferFallback? = nil,
        publicationController: SuggestionPublicationController? = nil,
        acceptanceSessionController: AcceptanceSessionController = AcceptanceSessionController(),
        inputController: SuggestionInputStateTracking = SuggestionInputController(),
        shortcutLeakRepairInserter: ShortcutLeakRepairing? = nil,
        suggestionDebugLogger: SuggestionDebugLogger? = nil,
        debugOptionsProvider: @escaping @MainActor () -> AutoCompDebugOptions = { .normal }
    ) {
        self.focusProvider = contextProvider
        self.generationProvider = completionProvider
        self.backendHealthMonitor = backendHealthMonitor
        self.backendStatusSummary = backendHealthMonitor.summary
        self.visualContextProvider = visualContextProvider
        self.clipboardContextProvider = clipboardContextProvider
        self.presenter = presenter
        self.inputController = inputController
        self.compatibilityCatalog = compatibilityCatalog
        self.compatibilitySettings = compatibilitySettings
        self.privacyStore = privacyStore
        self.productivityMetrics = productivityMetrics
        self.isMultiSuggestionEnabled = multiSuggestionEnabled
        self.eligibilityEvaluator = eligibilityEvaluator
        self.inputMethodStateProvider = inputMethodStateProvider
        self.keystrokeBufferFallback = keystrokeBufferFallback
        self.publicationController = publicationController ?? SuggestionPublicationController(presenter: presenter)
        self.acceptanceSessionController = acceptanceSessionController
        self.acceptanceController = SuggestionAcceptanceController(sessionController: acceptanceSessionController)
        self.shortcutLeakRepairInserter = shortcutLeakRepairInserter
        self.suggestionDebugLogger = suggestionDebugLogger
        self.debugOptionsProvider = debugOptionsProvider
    }

    func start() {
        stop()
        lifecycleController.start { [weak self] in
            await self?.refresh(source: .poll)
        }
    }

    func stop() {
        GeometryDebug.log("engine-stop current=\(debugSuggestionState())")
        lifecycleController.stop()
        predictionController.cancelAll()
        postAcceptanceRefreshTask?.cancel()
        postAcceptanceRefreshTask = nil
        acceptanceSessionController.clearAll()
        inputController.reset()
        presenter.hide()
    }

    func setAutocompleteEnabled(_ enabled: Bool) {
        guard isAutocompleteEnabled != enabled else {
            return
        }

        isAutocompleteEnabled = enabled
        dismissedContext = nil
        predictionController.cancelAll()
        acceptanceSessionController.clearAll()
        inputController.reset()
        currentSuggestion = nil
        if enabled {
            statusMessage = "AutoComp enabled"
        } else {
            currentContext = nil
            statusMessage = "AutoComp disabled"
        }
        GeometryDebug.log("engine-enabled enabled=\(enabled)")
        presenter.hide()
    }

    func hideSuggestion() {
        hideSuggestion(reason: "external-hide", context: currentContext)
    }

    func updateMultiSuggestionEnabled(_ enabled: Bool) {
        isMultiSuggestionEnabled = enabled
        if !enabled, currentSuggestion?.hasMultipleAlternatives == true {
            hideSuggestion(reason: "multi-suggestion-disabled", context: currentContext)
        }
    }

    var isMultiSuggestionPopupVisible: Bool {
        isMultiSuggestionEnabled && (currentSuggestion?.hasMultipleAlternatives == true)
    }

    func selectNextAlternative() {
        selectAlternative(offset: 1)
    }

    func selectPreviousAlternative() {
        selectAlternative(offset: -1)
    }

    func recordSuggestionTriggerKey(_ event: CapturedInputEvent) {
        recordCapturedInputEvent(event)
    }

    func recordCapturedInputEvent(_ event: CapturedInputEvent) {
        guard isAutocompleteEnabled else {
            return
        }

        let inputMethodState = inputMethodStateProvider()
        keystrokeBufferFallback?.record(
            event: event,
            currentContext: currentContext,
            inputMethodState: inputMethodState
        )
        let action = inputController.action(for: event)
        GeometryDebug.log("input-event \(action.logDescription)")

        if action.shouldClearSuggestion {
            clearSuggestion(for: action)
        }

        guard action.shouldSchedulePrediction else {
            return
        }

        Task { @MainActor [weak self] in
            await self?.refresh(source: .inputEvent(event))
        }
    }

    func dismissSuggestionUntilTextMutation() {
        dismissedContext = currentContext
        statusMessage = "Suggestion dismissed"
        predictionController.cancelAll()
        hideSuggestion(reason: "manual-dismiss", context: currentContext)
    }

    func triggerManualSuggestion() async {
        guard isAutocompleteEnabled else {
            statusMessage = "AutoComp disabled"
            return
        }

        let inputMethodState = inputMethodStateProvider()
        diagnostics.recordInputMethod(inputMethodState)

        do {
            let focusCaptureStartedAt = ContinuousClock.now
            let context = try await focusProvider.currentContext()
            let latencySeed = makeCompletionLatencySeed(
                startedAt: focusCaptureStartedAt,
                fallbackAXCaptureMs: elapsedMs(since: focusCaptureStartedAt)
            )
            transientFocusFailureStartedAt = nil
            recordTrustedContext(context)
            runManualSuggestion(
                for: context,
                inputMethodState: inputMethodState,
                latencySeed: latencySeed
            )
        } catch {
            if runManualFallbackSuggestion(after: error, inputMethodState: inputMethodState) {
                return
            }

            diagnostics.recordFocusFailure(error)
            currentContext = nil
            currentSuggestion = nil
            statusMessage = (error as? LocalizedError)?.errorDescription ?? "No compatible text field"
            GeometryDebug.log("manual-trigger-error status=\(statusMessage)")
            presenter.hide()
        }
    }

    private func runManualFallbackSuggestion(
        after error: Error,
        inputMethodState: InputMethodState
    ) -> Bool {
        guard let context = keystrokeBufferFallback?.fallbackContext(after: error) else {
            keystrokeBufferFallback?.observeFocusFailure(error)
            return false
        }

        transientFocusFailureStartedAt = nil
        let captureDiagnostics = ContextCaptureDiagnostics(context: context)
        GeometryDebug.log("manual-trigger fallback=low-trust source=\(captureDiagnostics.contextSourceLogValue) geometry=\(captureDiagnostics.geometryQualityLogValue) originalError=\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) context=\(debugContext(context))")
        runManualSuggestion(for: context, inputMethodState: inputMethodState)
        return true
    }

    private func runManualSuggestion(
        for context: TextContext,
        inputMethodState: InputMethodState,
        latencySeed: CompletionLatencySeed? = nil
    ) {
        recordFocusDiagnostics(context)
        let decision = eligibilityDecision(
            for: context,
            previousObservedContext: currentContext,
            invocation: .manual,
            inputMethodState: inputMethodState
        )
        diagnostics.recordEligibility(decision)
        logEligibilityDecision(decision)
        GeometryDebug.log("manual-trigger decision=\(debugEligibilityDecision(decision)) context=\(debugContext(context))")
        guard decision.isEligible else {
            applyIneligibleDecision(decision, context: context)
            return
        }

        dismissedContext = nil
        currentContext = context
        predictionController.cancelAll()
        acceptanceSessionController.clearAll()
        currentSuggestion = nil
        presenter.hide()
        requestCompletion(for: context, invocation: .manual, latencySeed: latencySeed)
    }

    func updateCompletionProvider(
        _ completionProvider: CompletionProvider,
        status: String,
        reason: CompletionProviderSwitchReason = .backendSwitch
    ) {
        let oldProvider = generationProvider
        GeometryDebug.log("engine-provider-update reason=\(reason.rawValue) status=\(status) current=\(debugSuggestionState())")
        switch reason {
        case .backendSwitch:
            prepareForBackendSwitch(reason: reason)
        case .runtimeModelSwitch:
            prepareForRuntimeModelSwitch()
        }
        self.generationProvider = completionProvider
        backendStatusSummary = backendHealthMonitor.reset()
        statusMessage = status
        shutdownOldProviderIfNeeded(oldProvider)
    }

    func prepareForBackendSwitch(reason: CompletionProviderSwitchReason) {
        let previousContext = currentContext
        providerLifecycleGeneration += 1
        predictionController.cancelAll()
        diagnostics.recordStaleDiscard(reason: reason.rawValue)
        hideSuggestion(reason: reason.rawValue, context: previousContext)
        resetCachedGenerationContext()
        clearAcceptanceSession()
        clearVisualContextSession()
    }

    func prepareForRuntimeModelSwitch() {
        prepareForBackendSwitch(reason: .runtimeModelSwitch)
    }

    private func resetCachedGenerationContext() {
        currentContext = nil
        dismissedContext = nil
        transientFocusFailureStartedAt = nil
        lastLatencyMs = nil
        postAcceptanceRefreshTask?.cancel()
        postAcceptanceRefreshTask = nil
        inputController.reset()
    }

    private func clearAcceptanceSession() {
        acceptanceSessionController.clearAll()
    }

    private func clearVisualContextSession() {
        guard let provider = visualContextProvider as? VisualContextSessionClearing else {
            return
        }
        provider.clearVisualContextSession()
    }

    private func shutdownOldProviderIfNeeded(_ provider: CompletionProvider) {
        guard let provider = provider as? RuntimeSwitchPreparingCompletionProvider else {
            return
        }
        Task.detached(priority: .utility) {
            await provider.prepareForRuntimeSwitch()
        }
    }

    func recordBackendProbeResult(_ result: RemoteBackendProbeResult) {
        switch result.status {
        case .connected:
            backendStatusSummary = backendHealthMonitor.recordSuccess()
        case .failed:
            if let issue = result.issue {
                backendStatusSummary = backendHealthMonitor.recordFailure(issue: issue)
            }
        }
        statusMessage = result.message
        GeometryDebug.log("backend-probe status=\(result.status.rawValue) message=\(result.message)")
    }

    @discardableResult
    func acceptNextWord(using inserter: TextInserter) async -> SuggestionAcceptanceCommandOutcome {
        let action = AcceptanceCommandAction.nextWord
        guard let liveContext = await revalidatedAcceptanceContext(for: action) else {
            return .passedThrough
        }

        do {
            let insertionStartedAt = ContinuousClock.now
            guard let result = try await acceptanceController.acceptNextWord(
                currentSuggestion: currentSuggestion,
                currentContext: liveContext,
                using: inserter
            ) else {
                GeometryDebug.log("acceptance passed-through action=\(action.debugName) reason=no-token context=\(debugContext(liveContext)) current=\(debugSuggestionState())")
                return .passedThrough
            }
            let insertionMs = elapsedMs(since: insertionStartedAt)
            GeometryDebug.log("acceptance accepted action=\(action.debugName) acceptedLength=\((result.acceptedText as NSString).length) context=\(debugContext(liveContext)) current=\(debugSuggestionState(result.currentSuggestion))")
            productivityMetrics?.recordAcceptedText(result.acceptedText)
            recordInsertionLatency(insertionMs)
            if result.shouldHidePresenter {
                GeometryDebug.log("completed-accept-all state=\(result.completedAcceptAllStateArmed ? "armed" : "nil") source=accept-next-word acceptedLength=\((result.acceptedText as NSString).length)")
            }
            currentSuggestion = result.currentSuggestion

            if let context = currentContext, let currentSuggestion {
                let presentationContext = result.presentationContext ?? context
                presenter.update(
                    currentSuggestion,
                    for: presentationContext,
                    mode: displayMode(for: presentationContext)
                )
            } else {
                presenter.hide()
            }
            schedulePostAcceptanceRefresh(for: action)
            return .accepted
        } catch {
            statusMessage = "Insertion failed"
            GeometryDebug.log("acceptance insert-failed action=\(action.debugName) error=\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) context=\(debugContext(liveContext)) current=\(debugSuggestionState())")
            return .failed
        }
    }

    @discardableResult
    func acceptAll(using inserter: TextInserter) async -> SuggestionAcceptanceCommandOutcome {
        let action = AcceptanceCommandAction.fullSuggestion
        guard let liveContext = await revalidatedAcceptanceContext(for: action) else {
            return .passedThrough
        }

        do {
            let insertionStartedAt = ContinuousClock.now
            guard let result = try await acceptanceController.acceptAll(
                currentSuggestion: currentSuggestion,
                currentContext: liveContext,
                using: inserter
            ) else {
                GeometryDebug.log("acceptance passed-through action=\(action.debugName) reason=no-token context=\(debugContext(liveContext)) current=\(debugSuggestionState())")
                return .passedThrough
            }
            let insertionMs = elapsedMs(since: insertionStartedAt)
            GeometryDebug.log("acceptance accepted action=\(action.debugName) acceptedLength=\((result.acceptedText as NSString).length) context=\(debugContext(liveContext)) current=\(debugSuggestionState(result.currentSuggestion))")
            productivityMetrics?.recordAcceptedText(result.acceptedText)
            recordInsertionLatency(insertionMs)
            GeometryDebug.log("completed-accept-all state=\(result.completedAcceptAllStateArmed ? "armed" : "nil") acceptedLength=\((result.acceptedText as NSString).length)")
            currentSuggestion = nil
            presenter.hide()
            schedulePostAcceptanceRefresh(for: action)
            return .accepted
        } catch {
            statusMessage = "Insertion failed"
            GeometryDebug.log("acceptance insert-failed action=\(action.debugName) error=\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) context=\(debugContext(liveContext)) current=\(debugSuggestionState())")
            return .failed
        }
    }

    private func revalidatedAcceptanceContext(for action: AcceptanceCommandAction) async -> TextContext? {
        guard currentSuggestion != nil else {
            statusMessage = "Suggestion unavailable"
            GeometryDebug.log("acceptance passed-through action=\(action.debugName) reason=\(AcceptanceSessionPassThroughReason.noSuggestion.rawValue) context=\(debugContext(currentContext)) current=\(debugSuggestionState())")
            hideSuggestion(reason: "acceptance-\(AcceptanceSessionPassThroughReason.noSuggestion.rawValue)", context: currentContext)
            return nil
        }

        let liveContext: TextContext
        do {
            liveContext = try await focusProvider.currentContext()
            transientFocusFailureStartedAt = nil
            recordTrustedContext(liveContext)
            recordFocusDiagnostics(liveContext)
        } catch {
            diagnostics.recordFocusFailure(error)
            statusMessage = "Suggestion unavailable"
            GeometryDebug.log("acceptance passed-through action=\(action.debugName) reason=\(AcceptanceSessionPassThroughReason.staleContext.rawValue) error=\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) context=\(debugContext(currentContext)) current=\(debugSuggestionState())")
            hideSuggestion(reason: "acceptance-\(AcceptanceSessionPassThroughReason.staleContext.rawValue)", context: currentContext)
            return nil
        }

        switch acceptanceSessionController.validateAcceptance(
            context: liveContext,
            currentSuggestion: currentSuggestion
        ) {
        case .valid:
            if let block = riskyHostAcceptanceBlock(action: action, context: liveContext) {
                currentContext = liveContext
                statusMessage = block.statusMessage
                diagnostics.recordRiskyHostAppBlock(action: block.diagnosticAction)
                GeometryDebug.log("acceptance passed-through action=\(action.debugName) reason=\(block.reason) context=\(debugContext(liveContext)) current=\(debugSuggestionState())")
                hideSuggestion(reason: "acceptance-\(block.reason)", context: liveContext)
                return nil
            }
            currentContext = liveContext
            return liveContext
        case .passedThrough(let reason):
            currentContext = liveContext
            statusMessage = "Suggestion unavailable"
            GeometryDebug.log("acceptance passed-through action=\(action.debugName) reason=\(reason.rawValue) context=\(debugContext(liveContext)) current=\(debugSuggestionState())")
            hideSuggestion(reason: "acceptance-\(reason.rawValue)", context: liveContext)
            return nil
        }
    }

    private func riskyHostAcceptanceBlock(
        action: AcceptanceCommandAction,
        context: TextContext
    ) -> RiskyHostAcceptanceBlock? {
        guard let category = RiskyHostAppPolicy.category(
            bundleID: context.app.bundleID,
            domain: context.domain
        ) else {
            return nil
        }

        guard RiskyHostAppPolicy.isClearlyEditableTarget(context) else {
            return RiskyHostAcceptanceBlock(
                reason: "blocked-risky-host-app",
                statusMessage: "Risky host app blocked",
                diagnosticAction: "Acceptance blocked because the target was not clearly editable in \(category.rawValue)."
            )
        }

        guard category == .chat,
              let acceptedText = pendingAcceptedText(action: action) else {
            return nil
        }

        if RiskyHostAppPolicy.containsReturn(acceptedText) {
            return RiskyHostAcceptanceBlock(
                reason: "blocked-risky-host-app",
                statusMessage: "Risky host app blocked",
                diagnosticAction: "Acceptance blocked because chat insertion contained Return."
            )
        }

        return nil
    }

    private func pendingAcceptedText(action: AcceptanceCommandAction) -> String? {
        guard var suggestion = currentSuggestion else {
            return nil
        }

        switch action {
        case .nextWord:
            return suggestion.acceptNextWord()
        case .fullSuggestion:
            return suggestion.acceptAll()
        }
    }

    private func schedulePostAcceptanceRefresh(for action: AcceptanceCommandAction) {
        postAcceptanceRefreshTask?.cancel()
        let delayNanoseconds = postAcceptanceRefreshDelayNanoseconds
        postAcceptanceRefreshTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delayNanoseconds)
            } catch {
                return
            }
            await self?.refresh(source: .poll)
        }
        GeometryDebug.log("acceptance-refresh scheduled action=\(action.debugName) delayMs=150")
    }

    private func refresh(source: SuggestionRefreshSource) async {
        guard isAutocompleteEnabled else {
            return
        }

        backendStatusSummary = backendHealthMonitor.refresh()

        do {
            let inputMethodState = inputMethodStateProvider()
            diagnostics.recordInputMethod(inputMethodState)
            let focusCaptureStartedAt = ContinuousClock.now
            let context = try await focusProvider.currentContext()
            let latencySeed = makeCompletionLatencySeed(
                startedAt: focusCaptureStartedAt,
                fallbackAXCaptureMs: elapsedMs(since: focusCaptureStartedAt)
            )
            transientFocusFailureStartedAt = nil
            recordTrustedContext(context)
            recordFocusDiagnostics(context)
            GeometryDebug.log("refresh source=\(source.debugName) context=\(debugContext(context)) previous=\(debugContext(currentContext)) current=\(debugSuggestionState())")

            if handleAppSwitchIfNeeded(context: context, source: source) {
                GeometryDebug.log("refresh-branch action=app-switch source=\(source.debugName) context=\(debugContext(context))")
                return
            }

            if dismissalStillApplies(to: context) {
                currentContext = context
                predictionController.cancelAll()
                currentSuggestion = nil
                statusMessage = "Suggestion dismissed"
                presenter.hide()
                GeometryDebug.log("refresh-branch action=dismissed-until-mutation context=\(debugContext(context))")
                return
            }

            if context.textBeforeCursor.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let decision = eligibilityDecision(
                    for: context,
                    previousObservedContext: currentContext,
                    inputMethodState: inputMethodState
                )
                diagnostics.recordEligibility(decision)
                logEligibilityDecision(decision)
                GeometryDebug.log("refresh-branch action=empty-context decision=\(debugEligibilityDecision(decision))")
                applyIneligibleDecision(decision, context: context)
                return
            }

            if await repairLeakedShortcutIfNeeded(context) {
                GeometryDebug.log("refresh-branch action=shortcut-repair")
                return
            }

            if repairCompletedAcceptAllLeakIfNeeded(context) {
                GeometryDebug.log("refresh-branch action=completed-accept-all-repair")
                return
            }

            if let suggestion = currentSuggestion,
               !suggestion.isExhausted,
               let previousContext = currentContext,
               isWebWhitespaceNormalizationDrift(context: context, previousContext: previousContext) {
                let presentationContext = context.replacingTextBeforeCursor(previousContext.textBeforeCursor)
                currentContext = presentationContext
                predictionController.cancelAll()
                GeometryDebug.log("suggestion-keep reason=web-whitespace-normalization context=\(debugContext(context)) previous=\(debugContext(previousContext)) current=\(debugSuggestionState(suggestion))")
                presenter.update(suggestion, for: presentationContext, mode: displayMode(for: presentationContext))
                return
            }

            if handleAcceptedSuggestionSession(context) {
                GeometryDebug.log("refresh-branch action=accepted-session")
                return
            }

            if let suggestion = currentSuggestion,
               !suggestion.isExhausted,
               let previousContext = currentContext,
               isSameFocusedText(context, as: previousContext) {
                currentContext = context
                GeometryDebug.log("suggestion-keep reason=same-focused-text context=\(debugContext(context)) current=\(debugSuggestionState(suggestion))")
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
                GeometryDebug.log("suggestion-keep reason=accepted-prefix-consistent context=\(debugContext(context)) previous=\(debugContext(prevContext)) current=\(debugSuggestionState(suggestion))")
                presenter.update(suggestion, for: context, mode: displayMode(for: context))
                return
            }

            let previousObservedContext = currentContext
            let eligibilityDecision = eligibilityDecision(
                for: context,
                previousObservedContext: previousObservedContext,
                inputMethodState: inputMethodState
            )
            diagnostics.recordEligibility(eligibilityDecision)
            logEligibilityDecision(eligibilityDecision)
            GeometryDebug.log("refresh-branch action=eligibility source=\(source.debugName) decision=\(debugEligibilityDecision(eligibilityDecision)) context=\(debugContext(context)) previous=\(debugContext(previousObservedContext)) current=\(debugSuggestionState())")
            guard eligibilityDecision.isEligible else {
                applyIneligibleDecision(eligibilityDecision, context: context)
                return
            }

            currentContext = context
            predictionController.cancelAll()
            acceptanceSessionController.clearAll()

            if let emojiSuggestion = emojiService.suggestion(for: context.textBeforeCursor, contextID: context.id) {
                GeometryDebug.log("completion-path source=emoji context=\(debugContext(context))")
                publish(
                    emojiSuggestion,
                    context: context,
                    latencyReport: completionLatencyReport(from: latencySeed),
                    latencyStartedAt: latencySeed.startedAt
                )
                return
            }

            // Debounce: hide the current suggestion and wait for the user to
            // stop typing before requesting a new completion.
            hideSuggestion(reason: "eligible-new-context", context: context)
            let debounceInterval = predictionController.debounceInterval
            let debounceStartedAt = ContinuousClock.now
            let debounceWorkID = predictionController.replaceDebouncedWork { [weak self, debounceInterval, latencySeed, debounceStartedAt] workID in
                try? await Task.sleep(nanoseconds: UInt64(debounceInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                guard let engine = self else { return }
                await MainActor.run {
                    guard engine.predictionController.isCurrent(workID) else {
                        GeometryDebug.log("completion-debounce skipped reason=stale-work workID=\(workID) generation=\(workID) source=\(source.debugName) context=\(engine.debugContext(context))")
                        return
                    }
                    GeometryDebug.log("completion-debounce fired workID=\(workID) generation=\(workID) source=\(source.debugName) context=\(engine.debugContext(context))")
                    var firedLatencySeed = latencySeed
                    firedLatencySeed.debounceMs = debounceStartedAt.duration(to: .now).appMilliseconds
                    engine.requestCompletion(
                        for: context,
                        invocation: .automatic,
                        latencySeed: firedLatencySeed
                    )
                }
            }
            GeometryDebug.log("completion-debounce scheduled workID=\(debounceWorkID) generation=\(debounceWorkID) source=\(source.debugName) interval=\(debounceInterval) context=\(debugContext(context))")
        } catch {
            keystrokeBufferFallback?.observeFocusFailure(error)
            diagnostics.recordFocusFailure(error)
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

    private func clearSuggestion(for action: SuggestionInputAction) {
        switch action.clearEventKind {
        case .dismissal:
            dismissSuggestionUntilTextMutation()
        case .textMutation:
            dismissedContext = nil
            predictionController.cancelAll()
            hideSuggestion(reason: "input-\(action.event.eventKind.rawValue)", context: currentContext)
        case .navigation, .shortcutMutation:
            predictionController.cancelAll()
            hideSuggestion(reason: "input-\(action.event.eventKind.rawValue)", context: currentContext)
        case .acceptance, .fullAcceptance, .manualTrigger, .other:
            break
        case nil:
            break
        }
    }

    private func handleAppSwitchIfNeeded(
        context: TextContext,
        source: SuggestionRefreshSource
    ) -> Bool {
        guard let previousContext = currentContext,
              previousContext.app != context.app else {
            return false
        }

        predictionController.cancelAll()
        currentSuggestion = nil
        acceptanceSessionController.clearAll()
        presenter.hide()
        currentContext = context
        dismissedContext = nil
        GeometryDebug.log("suggestion-hide reason=app-switch source=\(source.debugName) previous=\(debugContext(previousContext)) context=\(debugContext(context))")
        return source.shouldStopAfterAppSwitchClear
    }

    private func recordFocusDiagnostics(_ context: TextContext) {
        diagnostics.recordFocus(
            context: context,
            domainResolution: domainResolution(for: context)
        )
    }

    private func domainResolution(for context: TextContext) -> BrowserDomainResolution {
        if let reported = (focusProvider as? DomainResolutionReporting)?.lastDomainResolution {
            return reported.resolvingEffectiveDomain(context.domain)
        }
        return .inferred(domain: context.domain)
    }

    private func eligibilityDecision(
        for context: TextContext,
        previousObservedContext: TextContext?,
        invocation: SuggestionEligibilityInvocation = .automatic,
        inputMethodState: InputMethodState
    ) -> SuggestionEligibilityDecision {
        let compatibilityDecision = compatibilityCatalog.decision(
            bundleID: context.app.bundleID,
            domain: context.domain,
            userModeOverrides: compatibilitySettings.loadModeOverrides()
        )
        diagnostics.recordCompatibility(compatibilityDecision)

        return eligibilityEvaluator.evaluate(
            context: context,
            previousContext: previousObservedContext,
            compatibilityDecision: compatibilityDecision,
            lastSuggestionTriggerKeyAt: inputController.lastSuggestionTriggerKeyAt,
            invocation: invocation,
            inputMethodState: inputMethodState
        )
    }

    private func applyIneligibleDecision(
        _ decision: SuggestionEligibilityDecision,
        context: TextContext
    ) {
        GeometryDebug.log("ineligible-apply decision=\(debugEligibilityDecision(decision)) context=\(debugContext(context)) current=\(debugSuggestionState())")
        if let statusMessage = decision.statusMessage {
            self.statusMessage = statusMessage
        }

        switch decision.skipReason {
        case .emptyContext:
            currentContext = context
            predictionController.cancelAll()
            hideSuggestion(reason: "empty-context", context: context)
        case .compatibility, .manualOnlyWaitingForTrigger, .sentenceComplete:
            hideSuggestion(reason: decision.skipReason?.rawValue ?? "ineligible", context: context)
        case .unchangedContext:
            break
        case .inputSourceNonASCII, .imeCompositionActive:
            currentContext = context
            predictionController.cancelAll()
            hideSuggestion(reason: decision.skipReason?.rawValue ?? "input-method", context: context)
        case .awaitingSpaceTrigger, .selectionActive:
            currentContext = context
            predictionController.cancelAll()
            acceptanceSessionController.clearAcceptance()
            currentSuggestion = nil
            GeometryDebug.log("suggestion-hide reason=\(decision.skipReason?.rawValue ?? "ineligible") context=\(debugContext(context))")
            presenter.hide()
        case nil:
            break
        }
    }

    private func logEligibilityDecision(_ decision: SuggestionEligibilityDecision) {
        diagnosticsController.logEligibilityDecision(decision)
    }

    private func recordTrustedContext(_ context: TextContext) {
        keystrokeBufferFallback?.observeTrustedContext(context)
    }

    private func makeCompletionLatencySeed(
        startedAt: ContinuousClock.Instant,
        fallbackAXCaptureMs: Int
    ) -> CompletionLatencySeed {
        let focusLatency = (focusProvider as? FocusContextLatencyReporting)?.lastFocusContextLatencyReport
        return CompletionLatencySeed(
            startedAt: startedAt,
            axCaptureMs: focusLatency?.axCaptureMs ?? fallbackAXCaptureMs,
            geometryMs: focusLatency?.geometryMs,
            debounceMs: nil
        )
    }

    private func completionLatencyReport(from seed: CompletionLatencySeed?) -> CompletionLatencyReport {
        CompletionLatencyReport(
            axCaptureMs: seed?.axCaptureMs,
            geometryMs: seed?.geometryMs,
            debounceMs: seed?.debounceMs
        )
    }

    private func elapsedMs(since startedAt: ContinuousClock.Instant) -> Int {
        max(0, startedAt.duration(to: .now).appMilliseconds)
    }

    private func recordCompletionLatency(_ report: CompletionLatencyReport) {
        guard privacyStore.load().productivityMetricsEnabled else {
            diagnostics.recordLatency(nil)
            return
        }
        guard !report.isEmpty else {
            return
        }
        diagnostics.recordLatency(report)
        productivityMetrics?.recordCompletionLatency(report)
    }

    private func recordInsertionLatency(_ latencyMs: Int) {
        guard privacyStore.load().productivityMetricsEnabled else {
            diagnostics.recordLatency(nil)
            return
        }
        diagnostics.recordInsertionLatency(latencyMs)
        productivityMetrics?.recordInsertionLatency(latencyMs)
    }

    private func requestCompletion(
        for context: TextContext,
        invocation: CompletionInvocation = .automatic,
        latencySeed: CompletionLatencySeed? = nil
    ) {
        backendStatusSummary = backendHealthMonitor.refresh()
        if invocation == .automatic,
           let suppression = backendHealthMonitor.suppressionSummary() {
            inputController.clearSuggestionTrigger()
            currentContext = context
            predictionController.cancelAll()
            backendStatusSummary = suppression
            statusMessage = suppression.statusMessage()
            diagnostics.recordBackendPaused(suppression)
            let remainingSeconds = suppression.remainingSuppressionSeconds() ?? 0
            GeometryDebug.log("completion-suppressed reason=backend-paused issue=\(suppression.issue?.logValue ?? "unknown") remainingSeconds=\(remainingSeconds) context=\(debugContext(context))")
            recordAutocompleteDebug(
                context: context,
                privacySettings: privacyStore.load(),
                visualContext: nil,
                clipboardContext: nil,
                invocation: invocation,
                outcome: "suppressed",
                discardReason: "backend-paused"
            )
            hideSuggestion(reason: "backend-paused", context: context)
            return
        }

        inputController.clearSuggestionTrigger()
        diagnostics.recordBackendRequest(policy: routingPolicy())
        let requestedSignature = contextGenerationTracker.signature(for: context)
        let providerGeneration = providerLifecycleGeneration
        let latencyStartedAt = latencySeed?.startedAt ?? ContinuousClock.now
        let initialLatencyReport = completionLatencyReport(from: latencySeed)
        predictionController.replaceGenerationWork { [weak self] workID in
            GeometryDebug.log("completion-request workID=\(workID) generation=\(workID) app=\(context.app.displayName) bundle=\(context.app.bundleID) context=\(context.geometryDebugDescription)")
            guard let engine = self else { return }
            guard !Task.isCancelled else {
                await MainActor.run {
                    engine.recordAutocompleteDebug(
                        context: context,
                        privacySettings: engine.privacyStore.load(),
                        visualContext: nil,
                        clipboardContext: nil,
                        invocation: invocation,
                        outcome: "cancelled",
                        discardReason: "task-cancelled-before-start"
                    )
                }
                return
            }
            do {
                var latencyReport = initialLatencyReport
                let privacySettings = engine.privacyStore.load()
                let isLowTrustRequest = engine.isLowTrustContext(context)
                let visualContext: VisualContextSnapshot?
                if isLowTrustRequest || engine.visualContextProvider == nil {
                    visualContext = nil
                } else {
                    let visualContextStartedAt = ContinuousClock.now
                    visualContext = await engine.currentVisualContext(for: context)
                    latencyReport.visualContextMs = visualContextStartedAt.duration(to: .now).appMilliseconds
                }
                guard !Task.isCancelled else {
                    await MainActor.run {
                        engine.recordAutocompleteDebug(
                            context: context,
                            privacySettings: privacySettings,
                            visualContext: visualContext,
                            clipboardContext: nil,
                            invocation: invocation,
                            outcome: "cancelled",
                            discardReason: "task-cancelled-before-provider"
                        )
                    }
                    return
                }
                let workStillCurrentAfterVisual = await MainActor.run {
                    let isCurrent = engine.predictionController.isCurrent(workID)
                    if !isCurrent {
                        GeometryDebug.log("completion-discarded reason=backend-switch-before-provider requested=\(engine.debugContext(context))")
                        engine.recordAutocompleteDebug(
                            context: context,
                            privacySettings: privacySettings,
                            visualContext: visualContext,
                            clipboardContext: nil,
                            invocation: invocation,
                            outcome: "discarded",
                            discardReason: "backend-switch-before-provider"
                        )
                    }
                    return isCurrent
                }
                guard workStillCurrentAfterVisual else {
                    return
                }
                if visualContext != nil {
                    let liveContextAfterVisual: TextContext
                    do {
                        liveContextAfterVisual = try await engine.focusProvider.currentContext()
                    } catch {
                        await MainActor.run {
                            guard engine.predictionController.isCurrent(workID) else {
                                return
                            }
                            GeometryDebug.log("completion-discarded reason=missing-live-context-after-visual requested=\(engine.debugContext(context))")
                            engine.diagnostics.recordStaleDiscard(reason: "missing-live-context-after-visual")
                            engine.recordAutocompleteDebug(
                                context: context,
                                privacySettings: privacySettings,
                                visualContext: visualContext,
                                clipboardContext: nil,
                                invocation: invocation,
                                outcome: "discarded",
                                discardReason: "missing-live-context-after-visual"
                            )
                            engine.hideSuggestion(reason: "missing-live-context-after-visual", context: context)
                        }
                        return
                    }

                    let visualContextStillMatches = await MainActor.run {
                        engine.recordTrustedContext(liveContextAfterVisual)
                        return engine.contextGenerationTracker.matches(liveContextAfterVisual, signature: requestedSignature)
                            && engine.visualContext(visualContext, matches: liveContextAfterVisual)
                    }
                    guard visualContextStillMatches else {
                        await MainActor.run {
                            guard engine.predictionController.isCurrent(workID) else {
                                return
                            }
                            GeometryDebug.log("completion-discarded reason=stale-visual-context requested=\(engine.debugContext(context)) live=\(engine.debugContext(liveContextAfterVisual))")
                            engine.diagnostics.recordStaleDiscard(reason: "stale-visual-context")
                            engine.recordAutocompleteDebug(
                                context: context,
                                privacySettings: privacySettings,
                                visualContext: visualContext,
                                clipboardContext: nil,
                                invocation: invocation,
                                outcome: "discarded",
                                discardReason: "stale-visual-context"
                            )
                            engine.hideSuggestion(reason: "stale-visual-context", context: context)
                        }
                        return
                    }
                }
                let clipboardContext: ClipboardContextSnapshot?
                if isLowTrustRequest || engine.clipboardContextProvider == nil {
                    clipboardContext = nil
                } else {
                    let clipboardFilterStartedAt = ContinuousClock.now
                    clipboardContext = engine.clipboardContextProvider?.currentClipboardContext(
                        for: context,
                        privacySettings: privacySettings
                    )
                    latencyReport.clipboardFilterMs = clipboardFilterStartedAt.duration(to: .now).appMilliseconds
                }
                await MainActor.run {
                    guard engine.predictionController.isCurrent(workID) else {
                        return
                    }
                    engine.diagnostics.recordSupplementalContext(
                        context: context,
                        visualContext: visualContext,
                        clipboardContext: clipboardContext
                    )
                }
                let backendStartedAt = ContinuousClock.now
                let suggestions = try await engine.completeSuggestions(
                    context: context,
                    privacySettings: privacySettings,
                    visualContext: visualContext,
                    clipboardContext: clipboardContext,
                    invocation: invocation
                )
                latencyReport.backendMs = backendStartedAt.duration(to: .now).appMilliseconds
                let promptCacheStats = await engine.promptCacheStatsIfAvailable()
                let suggestion = engine.preparedSuggestion(from: suggestions, context: context)
                let completionLatencyReport = latencyReport
                await MainActor.run {
                    guard engine.predictionController.isCurrent(workID) else {
                        return
                    }
                    engine.backendStatusSummary = engine.backendHealthMonitor.recordSuccess()
                }
                if isLowTrustRequest {
                    await MainActor.run {
                        guard engine.predictionController.isCurrent(workID) else {
                            GeometryDebug.log("completion-discarded reason=stale-work requested=\(engine.debugContext(context)) live=low-trust")
                            if engine.providerLifecycleGeneration == providerGeneration {
                                engine.diagnostics.recordStaleDiscard(reason: "stale-work")
                            }
                            engine.recordAutocompleteDebug(
                                context: context,
                                privacySettings: privacySettings,
                                visualContext: visualContext,
                                clipboardContext: clipboardContext,
                                invocation: invocation,
                                outcome: "discarded",
                                suggestions: suggestions,
                                discardReason: "stale-work"
                            )
                            return
                        }

                        GeometryDebug.log("completion-success revalidation=skipped-low-trust context=\(engine.debugContext(context)) suggestion=\(engine.debugSuggestionState(suggestion))")
                        let result = engine.publish(
                            suggestion,
                            context: context,
                            latencyReport: completionLatencyReport,
                            latencyStartedAt: latencyStartedAt
                        )
                        engine.recordAutocompleteDebugPublication(
                            result,
                            context: context,
                            privacySettings: privacySettings,
                            visualContext: visualContext,
                            clipboardContext: clipboardContext,
                            invocation: invocation,
                            suggestions: suggestions
                        )
                        engine.diagnostics.recordPromptCache(promptCacheStats)
                    }
                    return
                }
                let liveContext: TextContext
                do {
                    liveContext = try await engine.focusProvider.currentContext()
                } catch {
                    await MainActor.run {
                        guard engine.predictionController.isCurrent(workID) else {
                            return
                        }
                        GeometryDebug.log("completion-discarded reason=missing-live-context requested=\(engine.debugContext(context))")
                        engine.diagnostics.recordStaleDiscard(reason: "missing-live-context")
                        engine.recordAutocompleteDebug(
                            context: context,
                            privacySettings: privacySettings,
                            visualContext: visualContext,
                            clipboardContext: clipboardContext,
                            invocation: invocation,
                            outcome: "discarded",
                            suggestions: suggestions,
                            discardReason: "missing-live-context"
                        )
                        engine.hideSuggestion(reason: "missing-live-context", context: context)
                    }
                    return
                }
                await MainActor.run {
                    guard engine.predictionController.isCurrent(workID) else {
                        GeometryDebug.log("completion-discarded reason=stale-work requested=\(engine.debugContext(context)) live=\(engine.debugContext(liveContext))")
                        if engine.providerLifecycleGeneration == providerGeneration {
                            engine.diagnostics.recordStaleDiscard(reason: "stale-work")
                        }
                        engine.recordAutocompleteDebug(
                            context: context,
                            privacySettings: privacySettings,
                            visualContext: visualContext,
                            clipboardContext: clipboardContext,
                            invocation: invocation,
                            outcome: "discarded",
                            suggestions: suggestions,
                            discardReason: "stale-work"
                        )
                        return
                    }

                    let liveContextMatchesRequest = engine.contextGenerationTracker.matches(liveContext, signature: requestedSignature)
                    engine.recordTrustedContext(liveContext)
                    GeometryDebug.log("completion-live-context match=\(liveContextMatchesRequest) requested=\(engine.debugContext(context)) live=\(engine.debugContext(liveContext))")
                    guard liveContextMatchesRequest else {
                        GeometryDebug.log("completion-discarded reason=stale-context requested=\(engine.debugContext(context)) live=\(engine.debugContext(liveContext))")
                        engine.diagnostics.recordStaleDiscard(reason: "stale-context")
                        engine.recordAutocompleteDebug(
                            context: context,
                            privacySettings: privacySettings,
                            visualContext: visualContext,
                            clipboardContext: clipboardContext,
                            invocation: invocation,
                            outcome: "discarded",
                            suggestions: suggestions,
                            discardReason: "stale-context"
                        )
                        return
                    }

                    GeometryDebug.log("completion-success context=\(engine.debugContext(liveContext)) suggestion=\(engine.debugSuggestionState(suggestion))")
                    let result = engine.publish(
                        suggestion,
                        context: liveContext,
                        latencyReport: completionLatencyReport,
                        latencyStartedAt: latencyStartedAt
                    )
                    engine.recordAutocompleteDebugPublication(
                        result,
                        context: context,
                        privacySettings: privacySettings,
                        visualContext: visualContext,
                        clipboardContext: clipboardContext,
                        invocation: invocation,
                        suggestions: suggestions
                    )
                    engine.diagnostics.recordPromptCache(promptCacheStats)
                }
                } catch {
                    await MainActor.run {
                        guard engine.predictionController.isCurrent(workID) else {
                            return
                        }
                        GeometryDebug.log("completion-failed context=\(engine.debugContext(context)) error=\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)")
                        engine.diagnostics.recordBackendFailure(error, kind: engine.routingPolicy()?.activeKind)
                        let healthSummary = engine.backendHealthMonitor.recordFailure(error)
                        if let healthSummary {
                            engine.backendStatusSummary = healthSummary
                        }
                        if let healthSummary, healthSummary.state == .paused {
                            let remainingSeconds = healthSummary.remainingSuppressionSeconds() ?? 0
                            engine.statusMessage = healthSummary.statusMessage()
                            engine.diagnostics.recordBackendPaused(healthSummary)
                            GeometryDebug.log("completion-paused issue=\(healthSummary.issue?.logValue ?? "unknown") remainingSeconds=\(remainingSeconds) consecutiveFailures=\(engine.backendHealthMonitor.circuitBreaker.consecutiveFailures)")
                        } else {
                            engine.statusMessage = SuggestionDiagnostics.message(for: error)
                        }
                        engine.recordAutocompleteDebug(
                            context: context,
                            privacySettings: engine.privacyStore.load(),
                            visualContext: nil,
                            clipboardContext: nil,
                            invocation: invocation,
                            outcome: "failed",
                            error: error
                        )
                        engine.hideSuggestion(reason: "completion-failed", context: context)
                    }
                }
            }
        }

    private func complete(
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?,
        clipboardContext: ClipboardContextSnapshot?
    ) async throws -> Suggestion {
        if let provider = generationProvider as? ClipboardContextAwareCompletionProvider {
            return try await provider.complete(
                context: context,
                privacySettings: privacySettings,
                visualContext: visualContext,
                clipboardContext: clipboardContext
            )
        }
        if let provider = generationProvider as? VisualContextAwareCompletionProvider {
            return try await provider.complete(
                context: context,
                privacySettings: privacySettings,
                visualContext: visualContext
            )
        }
        return try await generationProvider.complete(context: context)
    }

    private func completeSuggestions(
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?,
        clipboardContext: ClipboardContextSnapshot?,
        invocation: CompletionInvocation
    ) async throws -> [Suggestion] {
        let options = CompletionOptions(
            suggestionCount: shouldRequestMultipleSuggestions(for: context, invocation: invocation) ? 3 : 1
        )
        if let provider = generationProvider as? MultipleCompletionProvider {
            return try await provider.complete(
                context: context,
                privacySettings: privacySettings,
                visualContext: visualContext,
                clipboardContext: clipboardContext,
                options: options
            )
        }
        return [
            try await complete(
                context: context,
                privacySettings: privacySettings,
                visualContext: visualContext,
                clipboardContext: clipboardContext
            )
        ]
    }

    private func promptCacheStatsIfAvailable() async -> LlamaPromptCacheStats? {
        guard let provider = generationProvider as? PromptCacheReportingCompletionProvider else {
            return nil
        }
        return await provider.promptCacheStats()
    }

    private func selectAlternative(offset: Int) {
        guard isMultiSuggestionEnabled,
              var suggestion = currentSuggestion,
              suggestion.hasMultipleAlternatives,
              let context = currentContext else {
            statusMessage = "Suggestion unavailable"
            GeometryDebug.log("multi-suggestion-navigation ignored reason=unavailable")
            return
        }

        guard suggestion.selectAlternative(offset: offset) else {
            return
        }

        currentSuggestion = suggestion
        statusMessage = "Alternative \(suggestion.selectedAlternativeIndex + 1) of \(suggestion.alternatives.count) selected"
        presenter.update(suggestion, for: context, mode: displayMode(for: context))
        GeometryDebug.log("multi-suggestion-navigation selected=\(suggestion.selectedAlternativeIndex) count=\(suggestion.alternatives.count)")
    }

    private func shouldRequestMultipleSuggestions(
        for context: TextContext,
        invocation: CompletionInvocation
    ) -> Bool {
        guard isMultiSuggestionEnabled else {
            return false
        }
        if invocation == .manual {
            return true
        }
        if displayMode(for: context) == .mirrorWindow {
            return true
        }
        switch context.caretGeometryQuality {
        case .elementFrame, .unavailable:
            return true
        case .directCaret, .glyph, .lineMetric, .screenOCR:
            return false
        }
    }

    nonisolated private func preparedSuggestion(from suggestions: [Suggestion], context: TextContext) -> Suggestion {
        let nonEmpty = suggestions
            .filter { !$0.visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(3)
        guard let first = nonEmpty.first else {
            return Suggestion(baseContextID: context.id, visibleText: "", latencyMs: 0)
        }
        let alternatives = nonEmpty.map {
            SuggestionAlternative(visibleText: $0.visibleText, rawText: $0.rawText)
        }
        guard alternatives.count > 1 else {
            return first
        }
        return Suggestion(
            baseContextID: context.id,
            visibleText: first.visibleText,
            rawText: first.rawText,
            alternatives: alternatives,
            latencyMs: first.latencyMs
        )
    }

    private func currentVisualContext(for context: TextContext) async -> VisualContextSnapshot? {
        guard let visualContextProvider else {
            return nil
        }
        if let stableProvider = visualContextProvider as? StableFieldVisualContextProvider {
            return await stableProvider.currentVisualContext(for: context.stableFieldIdentity)
        }
        return await visualContextProvider.currentVisualContext()
    }

    nonisolated private func isLowTrustContext(_ context: TextContext) -> Bool {
        context.captureSources == [.keystrokeBufferLowTrust]
    }

    private func visualContext(
        _ visualContext: VisualContextSnapshot?,
        matches context: TextContext
    ) -> Bool {
        guard let visualIdentity = visualContext?.stableFieldIdentity else {
            return true
        }
        guard let contextIdentity = context.stableFieldIdentity else {
            return false
        }
        return visualIdentity == contextIdentity
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
            predictionController.cancelAll()
            self.statusMessage = statusMessage

            if let currentSuggestion {
                presenter.update(currentSuggestion, for: repairedContext, mode: displayMode(for: repairedContext))
            } else {
                GeometryDebug.log("suggestion-hide reason=shortcut-repair-exhausted context=\(debugContext(repairedContext))")
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
            GeometryDebug.log("suggestion-hide reason=transient-focus-grace-expired current=\(debugSuggestionState(suggestion))")
            return false
        }

        GeometryDebug.log("suggestion-keep reason=transient-focus-read-failure context=\(debugContext(context)) current=\(debugSuggestionState(suggestion))")
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
            && previousContext.textAfterCursor == context.textAfterCursor
            && previousContext.selectedText == context.selectedText
            && isSameInteractionTarget(context, as: previousContext)
    }

    private func dismissalStillApplies(to context: TextContext) -> Bool {
        guard let dismissedContext else {
            return false
        }

        if isSameFocusedText(context, as: dismissedContext) {
            return true
        }

        self.dismissedContext = nil
        return false
    }

    private func isSameInteractionTarget(_ context: TextContext, as previousContext: TextContext) -> Bool {
        guard context.app == previousContext.app,
              context.domain == previousContext.domain else {
            return false
        }

        if context.focusedElementID == previousContext.focusedElementID {
            return true
        }

        if let stableFieldIdentity = context.stableFieldIdentity,
           let previousStableFieldIdentity = previousContext.stableFieldIdentity,
           stableFieldIdentity.matchesStableTarget(previousStableFieldIdentity) {
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

    @discardableResult
    private func publish(
        _ suggestion: Suggestion,
        context: TextContext,
        latencyReport: CompletionLatencyReport? = nil,
        latencyStartedAt: ContinuousClock.Instant? = nil
    ) -> SuggestionPublicationResult {
        let mode = displayMode(for: context)
        let privacy = privacyStore.load()
        let privacyDecision = privacy.collectionDecision(
            appBundleID: context.app.bundleID,
            domain: context.domain
        )
        diagnostics.recordPrivacy(privacyDecision)
        let collectionAllowed = privacyDecision.allowed
        GeometryDebug.log("suggestion-publication attempt context=\(debugContext(context)) mode=\(mode.rawValue) raw=\(debugSuggestionState(suggestion))")
        let result = publicationController.publish(
            suggestion,
            context: context,
            displayMode: mode,
            collectionAllowed: collectionAllowed
        )
        logPublicationResult(result)

        var completedLatencyReport = latencyReport ?? CompletionLatencyReport()
        if completedLatencyReport.backendMs == nil {
            completedLatencyReport.backendMs = result.lastLatencyMs
        }
        completedLatencyReport.normalizationMs = result.normalizationMs
        completedLatencyReport.overlayMs = result.overlayMs
        if completedLatencyReport.totalMs == nil, let latencyStartedAt {
            completedLatencyReport.totalMs = elapsedMs(since: latencyStartedAt)
        }
        recordCompletionLatency(completedLatencyReport)

        switch result.outcome {
        case .published(let suggestion):
            diagnostics.recordBackendSuccess(
                rawText: suggestion.rawText,
                normalizedText: suggestion.visibleText,
                collectionAllowed: collectionAllowed,
                route: suggestion.completionRoute
            )
            currentSuggestion = suggestion
            acceptanceSessionController.recordPublication(context: context, suggestion: suggestion)
            GeometryDebug.log("suggestion-state action=published context=\(debugContext(context)) current=\(debugSuggestionState(suggestion))")
            lastLatencyMs = result.lastLatencyMs
            if let statusMessage = result.statusMessage {
                self.statusMessage = statusMessage
            }
        case .rejected:
            acceptanceSessionController.clearAll()
            currentSuggestion = nil
            GeometryDebug.log("suggestion-state action=rejected context=\(debugContext(context))")
        }

        return result
    }

    private func recordAutocompleteDebug(
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?,
        clipboardContext: ClipboardContextSnapshot?,
        invocation: CompletionInvocation,
        outcome: String,
        suggestions: [Suggestion] = [],
        publishedSuggestion: Suggestion? = nil,
        rejectionReason: String? = nil,
        discardReason: String? = nil,
        error: Error? = nil
    ) {
        guard let suggestionDebugLogger else {
            return
        }

        suggestionDebugLogger.recordAutocomplete(
            context: context,
            privacySettings: privacySettings,
            visualContext: visualContext,
            clipboardContext: clipboardContext,
            invocation: invocation.debugName,
            outcome: outcome,
            suggestions: suggestions,
            publishedSuggestion: publishedSuggestion,
            rejectionReason: rejectionReason,
            discardReason: discardReason,
            errorDescription: error.map { ($0 as? LocalizedError)?.errorDescription ?? $0.localizedDescription },
            routingPolicy: routingPolicy(),
            options: debugOptionsProvider()
        )
    }

    private func recordAutocompleteDebugPublication(
        _ result: SuggestionPublicationResult,
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?,
        clipboardContext: ClipboardContextSnapshot?,
        invocation: CompletionInvocation,
        suggestions: [Suggestion]
    ) {
        switch result.outcome {
        case .published(let suggestion):
            recordAutocompleteDebug(
                context: context,
                privacySettings: privacySettings,
                visualContext: visualContext,
                clipboardContext: clipboardContext,
                invocation: invocation,
                outcome: "published",
                suggestions: suggestions,
                publishedSuggestion: suggestion
            )
        case .rejected(let reason):
            recordAutocompleteDebug(
                context: context,
                privacySettings: privacySettings,
                visualContext: visualContext,
                clipboardContext: clipboardContext,
                invocation: invocation,
                outcome: "rejected",
                suggestions: suggestions,
                rejectionReason: reason.rawValue
            )
        }
    }

    private func displayMode(for context: TextContext) -> SuggestionDisplayMode {
        compatibilityCatalog.decision(
            bundleID: context.app.bundleID,
            domain: context.domain,
            userModeOverrides: compatibilitySettings.loadModeOverrides()
        ).mode
    }

    private func logPublicationResult(_ result: SuggestionPublicationResult) {
        diagnosticsController.logPublicationResult(result)
    }

    private func routingPolicy() -> CompletionRoutingPolicy? {
        (generationProvider as? CompletionRoutingProviding)?.routingPolicy
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
            if !handledResult.shouldSchedulePrediction {
                currentContext = context
            }
            predictionController.cancelAll()
            currentSuggestion = handledResult.currentSuggestion
            GeometryDebug.log("accepted-session handled context=\(debugContext(context)) current=\(debugSuggestionState()) status=\(handledResult.statusMessage)")

            if let currentSuggestion {
                presenter.update(currentSuggestion, for: context, mode: displayMode(for: context))
            } else {
                GeometryDebug.log("suggestion-hide reason=accepted-session-exhausted context=\(debugContext(context))")
                presenter.hide()
            }

            statusMessage = handledResult.statusMessage
            return !handledResult.shouldSchedulePrediction
        case .cleared:
            currentSuggestion = nil
            GeometryDebug.log("suggestion-hide reason=accepted-session-cleared context=\(debugContext(context))")
            presenter.hide()
            return false
        }
    }

    private func hideSuggestion(reason: String, context: TextContext?) {
        GeometryDebug.log("suggestion-hide reason=\(reason) context=\(debugContext(context)) current=\(debugSuggestionState())")
        if currentSuggestion != nil {
            productivityMetrics?.recordDismissedSuggestion()
        }
        currentSuggestion = nil
        acceptanceSessionController.clearAll()
        presenter.hide()
    }

    private func debugContext(_ context: TextContext?) -> String {
        diagnosticsController.contextDescription(context)
    }

    private func debugSuggestionState(_ suggestion: Suggestion? = nil) -> String {
        diagnosticsController.suggestionDescription(suggestion ?? currentSuggestion)
    }

    private func debugEligibilityDecision(_ decision: SuggestionEligibilityDecision) -> String {
        diagnosticsController.eligibilityDescription(decision)
    }
}
