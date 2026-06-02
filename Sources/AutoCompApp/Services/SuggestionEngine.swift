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

private enum AcceptanceCommandAction: Sendable {
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

private struct ProviderInvocationFailureError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

enum SuggestionAcceptanceCommandOutcome: Equatable {
    case accepted
    case passedThrough
    case failed
}

private enum SuggestionRefreshSource: Equatable, Sendable {
    /// Refresh triggered by direct user input observation (key/mouse/etc.).
    case inputEvent(CapturedInputEvent)

    /// Refresh triggered by focus/active-app related events.
    case focusChanged
    case activeAppChanged

    /// Refresh triggered when an acceptance attempt was blocked and we should immediately regenerate.
    case acceptanceGuardrail

    /// Refresh after accepted text should have been published by the host app.
    case postAcceptance(AcceptanceCommandAction)

    /// Refresh after repairing a leaked shortcut suffix in the host app.
    case shortcutLeakRepair

    /// Safety-net refresh used only for adaptive fallback mechanisms (not continuous).
    case fallbackTimer

    /// Passive first refresh used to initialize diagnostics and focus state.
    case startup

    var debugName: String {
        switch self {
        case .inputEvent(let event):
            return "input-\(event.eventKind.rawValue)-\(event.debugName)"
        case .focusChanged:
            return "focus-changed"
        case .activeAppChanged:
            return "active-app-changed"
        case .acceptanceGuardrail:
            return "acceptance-guardrail"
        case .postAcceptance(let action):
            return "post-acceptance-\(action.debugName)"
        case .shortcutLeakRepair:
            return "shortcut-leak-repair"
        case .fallbackTimer:
            return "fallback-timer"
        case .startup:
            return "startup"
        }
    }

    var shouldStopAfterAppSwitchClear: Bool {
        self == .fallbackTimer
    }
}

@MainActor
final class SuggestionEngine: ObservableObject {

    private let guardrailLogger = AutoCompLogger(category: "guardrails")

    struct ProviderServices {
        let generationProvider: CompletionProvider
        let backendHealthMonitor: BackendHealthMonitor
        let visualContextProvider: VisualContextProvider?
        let clipboardContextProvider: ClipboardContextProvider?
        let keystrokeBufferFallback: KeystrokeBufferFallback?
    }

    struct PrivacyServices {
        let privacyStore: PrivacySettingsStore
        let compatibilityCatalog: CompatibilityCatalog
        let compatibilitySettings: CompatibilitySettingsStore
    }

    struct DiagnosticsServices {
        let productivityMetrics: ProductivityMetricsRecording?
        let suggestionDebugLogger: SuggestionDebugLogger?
        let debugOptionsProvider: @MainActor () -> AutoCompDebugOptions
    }
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
    private let personalizationRecorder: PersonalizationSampleRecorder?
    private let productivityMetrics: ProductivityMetricsRecording?
    private let eligibilityEvaluator: SuggestionEligibilityEvaluator

    private let providerServices: ProviderServices
    private let privacyServices: PrivacyServices
    private let diagnosticsServices: DiagnosticsServices
    private let inputMethodStateProvider: @Sendable () -> InputMethodState
    private let keystrokeBufferFallback: KeystrokeBufferFallback?
    private let publicationController: SuggestionPublicationController
    private let acceptanceSessionController: AcceptanceSessionController
    private let acceptanceController: SuggestionAcceptanceController
    private let shortcutLeakRepairInserter: ShortcutLeakRepairing?
    private let emojiService = EmojiSuggestionService()
    private let lifecycleController = SuggestionLifecycleController()
    private let predictionController = SuggestionPredictionController()
    private let hostPublishAwaiter: HostPublishAwaiter
    private let diagnosticsController = SuggestionDiagnosticsController()
    private let contextGenerationTracker = ContextGenerationTracker()
    private let suggestionDebugLogger: SuggestionDebugLogger?
    private let debugOptionsProvider: @MainActor () -> AutoCompDebugOptions

    private var providerLifecycleGeneration = 0
    private var dismissedContext: TextContext?
    private var postAcceptanceRefreshTask: Task<Void, Never>?
    private var visualContextRefreshTask: Task<Void, Never>?

    // Refresh single-flight state: prevents overlapping refreshes and coalesces bursts.
    private var refreshTask: Task<Void, Never>?
    private var refreshQueuedSource: SuggestionRefreshSource?

    private var transientFocusFailureStartedAt: Date?
    private let transientFocusFailureGraceInterval: TimeInterval = 1.5
    private let navigationClearSuppressionInterval: TimeInterval = 1.5
    private var navigationClearSuppressedUntil: Date = .distantPast
    private var interactionPipelineSuspensionReason: String?

    var isInteractionPipelineSuspended: Bool {
        interactionPipelineSuspensionReason != nil
    }

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
        personalizationRecorder: PersonalizationSampleRecorder? = nil,
        productivityMetrics: ProductivityMetricsRecording? = nil,
        multiSuggestionEnabled: Bool = CompletionBackendSettings.defaultMultiSuggestionEnabled,
        eligibilityEvaluator: SuggestionEligibilityEvaluator = SuggestionEligibilityEvaluator(),
        inputMethodStateProvider: @escaping @Sendable () -> InputMethodState = { .asciiCompatible },
        keystrokeBufferFallback: KeystrokeBufferFallback? = nil,
        publicationController: SuggestionPublicationController? = nil,
        acceptanceSessionController: AcceptanceSessionController = AcceptanceSessionController(),
        inputController: SuggestionInputStateTracking = SuggestionInputController(),
        shortcutLeakRepairInserter: ShortcutLeakRepairing? = nil,
        hostPublishAwaiter: HostPublishAwaiter = HostPublishAwaiter(),
        suggestionDebugLogger: SuggestionDebugLogger? = nil,
        debugOptionsProvider: @escaping @MainActor () -> AutoCompDebugOptions = { .normal }
    ) {
        self.focusProvider = contextProvider

        self.providerServices = ProviderServices(
            generationProvider: completionProvider,
            backendHealthMonitor: backendHealthMonitor,
            visualContextProvider: visualContextProvider,
            clipboardContextProvider: clipboardContextProvider,
            keystrokeBufferFallback: keystrokeBufferFallback
        )
        self.generationProvider = completionProvider
        self.backendHealthMonitor = backendHealthMonitor
        self.backendStatusSummary = backendHealthMonitor.summary
        self.visualContextProvider = visualContextProvider
        self.clipboardContextProvider = clipboardContextProvider
        self.keystrokeBufferFallback = keystrokeBufferFallback

        self.privacyServices = PrivacyServices(
            privacyStore: privacyStore,
            compatibilityCatalog: compatibilityCatalog,
            compatibilitySettings: compatibilitySettings
        )
        self.compatibilityCatalog = compatibilityCatalog
        self.compatibilitySettings = compatibilitySettings
        self.privacyStore = privacyStore
        self.personalizationRecorder = personalizationRecorder

        self.diagnosticsServices = DiagnosticsServices(
            productivityMetrics: productivityMetrics,
            suggestionDebugLogger: suggestionDebugLogger,
            debugOptionsProvider: debugOptionsProvider
        )
        self.productivityMetrics = productivityMetrics
        self.suggestionDebugLogger = suggestionDebugLogger
        self.debugOptionsProvider = debugOptionsProvider

        self.presenter = presenter
        self.inputController = inputController
        self.isMultiSuggestionEnabled = multiSuggestionEnabled
        self.eligibilityEvaluator = eligibilityEvaluator
        self.inputMethodStateProvider = inputMethodStateProvider
        self.publicationController = publicationController ?? SuggestionPublicationController(presenter: presenter)
        self.acceptanceSessionController = acceptanceSessionController
        self.acceptanceController = SuggestionAcceptanceController(sessionController: acceptanceSessionController)
        self.shortcutLeakRepairInserter = shortcutLeakRepairInserter
        self.hostPublishAwaiter = hostPublishAwaiter
    }

    func start() {
        guard !lifecycleController.isRunning else {
            RefreshDiagnostics.log("engine-start skipped reason=already-running")
            return
        }

        stop()

        lifecycleController.onActiveAppChanged = { [weak self] in
            self?.requestRefresh(source: .activeAppChanged)
            self?.lifecycleController.beginAdaptiveFallbackBurst()
        }
        lifecycleController.onFocusChanged = { [weak self] in
            // Guardrail: suggestions must not survive a focused element change.
            // Hide immediately so there is no window where an old suggestion could be accepted.
            self?.guardrailLogger.info("guardrail event=focus-changed action=hide")
            self?.hideSuggestion(reason: "focus-changed", context: self?.currentContext)
            self?.requestRefresh(source: .focusChanged)
            self?.lifecycleController.beginAdaptiveFallbackBurst()
        }
        lifecycleController.onFallbackTick = { [weak self] in
            self?.requestRefresh(source: .fallbackTimer)
        }
        lifecycleController.start()
        startVisualContextRefreshTimer()
        requestRefresh(source: .startup)
        lifecycleController.beginAdaptiveFallbackBurst()
    }

    func stop() {
        GeometryDebug.log("engine-stop current=\(debugSuggestionState())")
        lifecycleController.stop()
        visualContextRefreshTask?.cancel()
        visualContextRefreshTask = nil
        (visualContextProvider as? VisualContextSessionControlling)?.stopAndClear()
        predictionController.cancelAll()
        hostPublishAwaiter.cancelAll(reason: "engine-stop")
        navigationClearSuppressedUntil = .distantPast

        refreshTask?.cancel()
        refreshTask = nil
        refreshQueuedSource = nil

        postAcceptanceRefreshTask?.cancel()
        postAcceptanceRefreshTask = nil
        acceptanceSessionController.clearAll()
        inputController.reset()
        presenter.hide()
    }

    private func startVisualContextRefreshTimer() {
        guard visualContextProvider is VisualContextSessionControlling else {
            return
        }

        visualContextRefreshTask?.cancel()
        visualContextRefreshTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                guard !Task.isCancelled else {
                    return
                }
                (self?.visualContextProvider as? VisualContextSessionControlling)?.refreshTick()
            }
        }
    }

    func setInteractionPipelineSuspended(_ suspended: Bool, reason: String) {
        if suspended {
            guard interactionPipelineSuspensionReason == nil else {
                interactionPipelineSuspensionReason = reason
                return
            }

            interactionPipelineSuspensionReason = reason
            providerLifecycleGeneration += 1
            predictionController.cancelAll()
            hostPublishAwaiter.cancelAll(reason: "pipeline-suspended-\(reason)")
            diagnostics.recordStaleDiscard(reason: "pipeline-suspended-\(reason)")

            refreshTask?.cancel()
            refreshTask = nil
            refreshQueuedSource = nil
            postAcceptanceRefreshTask?.cancel()
            postAcceptanceRefreshTask = nil
            dismissedContext = nil
            transientFocusFailureStartedAt = nil
            acceptanceSessionController.clearAll()
            inputController.reset()
            currentSuggestion = nil
            statusMessage = "AutoComp paused"
            clearVisualContextSession()
            presenter.hide()
            GeometryDebug.log("engine-pipeline-suspension suspended=true reason=\(reason)")
        } else {
            guard interactionPipelineSuspensionReason != nil else {
                return
            }

            interactionPipelineSuspensionReason = nil
            if isAutocompleteEnabled {
                statusMessage = "AutoComp resumed"
            }
            GeometryDebug.log("engine-pipeline-suspension suspended=false reason=\(reason)")
        }
    }

    func setAutocompleteEnabled(_ enabled: Bool) {
        guard isAutocompleteEnabled != enabled else {
            return
        }

        isAutocompleteEnabled = enabled
        dismissedContext = nil
        predictionController.cancelAll()
        hostPublishAwaiter.cancelAll(reason: "autocomplete-toggle")
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

    func shortcutOwnershipDecision(
        for command: KeyboardShortcutCommand,
        isSuggestionVisible: Bool
    ) -> ShortcutOwnershipDecision {
        if isInteractionPipelineSuspended {
            return .passThrough(reason: "pipeline-suspended")
        }

        switch command {
        case .manualTrigger, .toggleAutocomplete:
            return .consume(reason: "global-command")
        case .selectPreviousSuggestion, .selectNextSuggestion:
            guard isSuggestionVisible else {
                return .passThrough(reason: "no-visible-suggestion")
            }
            return isMultiSuggestionPopupVisible
                ? .consume(reason: "multi-suggestion-visible")
                : .passThrough(reason: "multi-suggestion-hidden")
        case .dismissSuggestion:
            guard isSuggestionVisible, currentSuggestion != nil else {
                return .passThrough(reason: "no-visible-suggestion")
            }
            return .consume(reason: "dismiss-visible-suggestion")
        case .acceptNextWord:
            return acceptanceShortcutOwnershipDecision(
                command: command,
                action: .nextWord,
                isSuggestionVisible: isSuggestionVisible
            )
        case .acceptFullSuggestion:
            return acceptanceShortcutOwnershipDecision(
                command: command,
                action: .fullSuggestion,
                isSuggestionVisible: isSuggestionVisible
            )
        }
    }

    private func acceptanceShortcutOwnershipDecision(
        command: KeyboardShortcutCommand,
        action: AcceptanceCommandAction,
        isSuggestionVisible: Bool
    ) -> ShortcutOwnershipDecision {
        guard isSuggestionVisible else {
            return .passThrough(reason: "no-visible-suggestion")
        }

        guard let suggestion = currentSuggestion else {
            hideSuggestion(reason: "shortcut-ownership-no-suggestion", context: currentContext)
            return .passThrough(reason: "no-current-suggestion")
        }

        guard !suggestion.isExhausted else {
            hideSuggestion(reason: "shortcut-ownership-suggestion-exhausted", context: currentContext)
            return .passThrough(reason: "suggestion-exhausted")
        }

        guard let context = currentContext else {
            hideSuggestion(reason: "shortcut-ownership-no-current-context", context: nil)
            return .passThrough(reason: "no-current-context")
        }

        switch validateGuardrailedAcceptance(context: context, action: action) {
        case .valid:
            if let block = riskyHostAcceptanceBlock(action: action, context: context) {
                currentContext = context
                statusMessage = block.statusMessage
                diagnostics.recordRiskyHostAppBlock(action: block.diagnosticAction)
                GeometryDebug.log("shortcut-ownership acceptance-blocked command=\(command.rawValue) reason=\(block.reason) context=\(debugContext(context)) current=\(debugSuggestionState())")
                guardrailLogger.info("guardrail event=shortcut-ownership action=hide reason=\(block.reason) actionKind=\(action.debugName)")
                hideSuggestion(reason: "shortcut-ownership-\(block.reason)", context: context)
                return .passThrough(reason: block.reason)
            }

            return .consume(reason: "valid-suggestion")
        case .passedThrough(let reason):
            currentContext = context
            statusMessage = "Suggestion unavailable"
            GeometryDebug.log("shortcut-ownership acceptance-blocked command=\(command.rawValue) reason=\(reason.rawValue) context=\(debugContext(context)) current=\(debugSuggestionState())")
            hideSuggestion(reason: "shortcut-ownership-\(reason.rawValue)", context: context)
            if action == .fullSuggestion,
               reason != .noSuggestion,
               reason != .unexpectedSelection {
                predictionController.cancelAll()
                requestCompletion(for: context, invocation: .manual)
                statusMessage = "Refreshing suggestion"
            }
            return .passThrough(reason: "stale-\(reason.rawValue)")
        }
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

        guard !isInteractionPipelineSuspended else {
            GeometryDebug.log("input-event ignored reason=pipeline-suspended eventKind=\(event.eventKind.rawValue) kind=\(event.debugName)")
            return
        }

        let inputMethodState = inputMethodStateProvider()
        keystrokeBufferFallback?.record(
            event: event,
            currentContext: currentContext,
            inputMethodState: inputMethodState
        )
        let action = inputController.action(for: event)
        let hostPublishBaseline = currentContext
        updateNavigationClearSuppression(for: action)
        let clearsSuggestion = shouldClearSuggestion(for: action)
        GeometryDebug.log("input-event \(action.logDescription)")
        SuggestionPipelineLog.log("input-event", fields: [
            "eventKind=\(event.eventKind.rawValue)",
            "kind=\(event.debugName)",
            "schedule=\(action.shouldSchedulePrediction)",
            "clear=\(clearsSuggestion)",
            "clearKind=\(clearsSuggestion ? event.eventKind.rawValue : "nil")",
            "current=\(SuggestionPipelineLog.suggestionDescription(currentSuggestion))"
        ])

        if clearsSuggestion {
            clearSuggestion(for: action)
        }

        guard shouldAwaitHostPublish(for: action) else {
            if shouldCancelHostPublish(for: action) {
                hostPublishAwaiter.cancelAll(reason: "input-\(event.eventKind.rawValue)-\(event.debugName)")
            }
            return
        }

        Task { @MainActor [weak self] in
            await self?.awaitHostPublishThenRefresh(
                source: .inputEvent(event),
                baseline: hostPublishBaseline,
                refreshOnTimeout: action.shouldSchedulePrediction
            )
        }
    }

    func dismissSuggestionUntilTextMutation() {
        dismissedContext = currentContext
        statusMessage = "Suggestion dismissed"
        predictionController.cancelAll()
        hostPublishAwaiter.cancelAll(reason: "manual-dismiss")
        hideSuggestion(reason: "manual-dismiss", context: currentContext)
    }

    func triggerManualSuggestion() async {
        guard isAutocompleteEnabled else {
            statusMessage = "AutoComp disabled"
            return
        }

        guard !isInteractionPipelineSuspended else {
            statusMessage = "AutoComp paused"
            GeometryDebug.log("manual-trigger skipped reason=pipeline-suspended")
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
            SuggestionPipelineLog.log("manual-context-captured", fields: [
                "context=\(SuggestionPipelineLog.contextDescription(context))"
            ])
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
            SuggestionPipelineLog.log("manual-context-failed", fields: [
                "error=\(SuggestionPipelineLog.privacySafeErrorSummary(error))"
            ])
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
        SuggestionPipelineLog.log("manual-eligibility", fields: [
            "decision=\(debugEligibilityDecision(decision))",
            "context=\(SuggestionPipelineLog.contextDescription(context))"
        ])
        guard decision.isEligible else {
            applyIneligibleDecision(decision, context: context)
            return
        }

        dismissedContext = nil
        currentContext = context
        predictionController.cancelAll()
        hostPublishAwaiter.cancelAll(reason: "manual-trigger")
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
        SuggestionPipelineLog.log("provider-update", fields: [
            "reason=\(reason.rawValue)",
            "current=\(SuggestionPipelineLog.suggestionDescription(currentSuggestion))"
        ])
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
        hostPublishAwaiter.cancelAll(reason: reason.rawValue)
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
        hostPublishAwaiter.cancelAll(reason: "reset-cached-generation-context")
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
        guard !isInteractionPipelineSuspended else {
            statusMessage = "AutoComp paused"
            GeometryDebug.log("acceptance passed-through action=next-word reason=pipeline-suspended context=\(debugContext(currentContext)) current=\(debugSuggestionState())")
            return .passedThrough
        }

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
            SuggestionPipelineLog.log("acceptance-accepted", fields: [
                "action=\(action.debugName)",
                "acceptedLen=\((result.acceptedText as NSString).length)",
                "insertionMs=\(insertionMs)",
                "context=\(SuggestionPipelineLog.contextDescription(liveContext))",
                "current=\(SuggestionPipelineLog.suggestionDescription(result.currentSuggestion))"
            ])
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
            schedulePostAcceptanceRefresh(for: action, baseline: liveContext)
            return .accepted
        } catch {
            statusMessage = "Insertion failed"
            GeometryDebug.log("acceptance insert-failed action=\(action.debugName) error=\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) context=\(debugContext(liveContext)) current=\(debugSuggestionState())")
            SuggestionPipelineLog.log("acceptance-insert-failed", fields: [
                "action=\(action.debugName)",
                "error=\(SuggestionPipelineLog.privacySafeErrorSummary(error))",
                "context=\(SuggestionPipelineLog.contextDescription(liveContext))",
                "current=\(SuggestionPipelineLog.suggestionDescription(currentSuggestion))"
            ])
            return .failed
        }
    }

    @discardableResult
    func acceptAll(using inserter: TextInserter) async -> SuggestionAcceptanceCommandOutcome {
        guard !isInteractionPipelineSuspended else {
            statusMessage = "AutoComp paused"
            GeometryDebug.log("acceptance passed-through action=full-suggestion reason=pipeline-suspended context=\(debugContext(currentContext)) current=\(debugSuggestionState())")
            return .passedThrough
        }

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
            SuggestionPipelineLog.log("acceptance-accepted", fields: [
                "action=\(action.debugName)",
                "acceptedLen=\((result.acceptedText as NSString).length)",
                "insertionMs=\(insertionMs)",
                "context=\(SuggestionPipelineLog.contextDescription(liveContext))",
                "current=\(SuggestionPipelineLog.suggestionDescription(result.currentSuggestion))"
            ])
            productivityMetrics?.recordAcceptedText(result.acceptedText)
            recordInsertionLatency(insertionMs)
            GeometryDebug.log("completed-accept-all state=\(result.completedAcceptAllStateArmed ? "armed" : "nil") acceptedLength=\((result.acceptedText as NSString).length)")
            currentSuggestion = nil
            presenter.hide()
            schedulePostAcceptanceRefresh(for: action, baseline: liveContext)
            return .accepted
        } catch {
            statusMessage = "Insertion failed"
            GeometryDebug.log("acceptance insert-failed action=\(action.debugName) error=\((error as? LocalizedError)?.errorDescription ?? error.localizedDescription) context=\(debugContext(liveContext)) current=\(debugSuggestionState())")
            SuggestionPipelineLog.log("acceptance-insert-failed", fields: [
                "action=\(action.debugName)",
                "error=\(SuggestionPipelineLog.privacySafeErrorSummary(error))",
                "context=\(SuggestionPipelineLog.contextDescription(liveContext))",
                "current=\(SuggestionPipelineLog.suggestionDescription(currentSuggestion))"
            ])
            return .failed
        }
    }

    private func revalidatedAcceptanceContext(for action: AcceptanceCommandAction) async -> TextContext? {
        guard currentSuggestion != nil else {
            statusMessage = "Suggestion unavailable"
            GeometryDebug.log("acceptance passed-through action=\(action.debugName) reason=\(AcceptanceSessionPassThroughReason.noSuggestion.rawValue) context=\(debugContext(currentContext)) current=\(debugSuggestionState())")
            SuggestionPipelineLog.log("acceptance-passed-through", fields: [
                "action=\(action.debugName)",
                "reason=\(AcceptanceSessionPassThroughReason.noSuggestion.rawValue)",
                "context=\(SuggestionPipelineLog.contextDescription(currentContext))",
                "current=\(SuggestionPipelineLog.suggestionDescription(currentSuggestion))"
            ])
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
            SuggestionPipelineLog.log("acceptance-passed-through", fields: [
                "action=\(action.debugName)",
                "reason=\(AcceptanceSessionPassThroughReason.staleContext.rawValue)",
                "error=\(SuggestionPipelineLog.privacySafeErrorSummary(error))",
                "context=\(SuggestionPipelineLog.contextDescription(currentContext))",
                "current=\(SuggestionPipelineLog.suggestionDescription(currentSuggestion))"
            ])
            hideSuggestion(reason: "acceptance-\(AcceptanceSessionPassThroughReason.staleContext.rawValue)", context: currentContext)
            return nil
        }

        switch validateGuardrailedAcceptance(
            context: liveContext,
            action: action
        ) {
        case .valid:
            if let block = riskyHostAcceptanceBlock(action: action, context: liveContext) {
                currentContext = liveContext
                statusMessage = block.statusMessage
                diagnostics.recordRiskyHostAppBlock(action: block.diagnosticAction)
                GeometryDebug.log("acceptance passed-through action=\(action.debugName) reason=\(block.reason) context=\(debugContext(liveContext)) current=\(debugSuggestionState())")
                SuggestionPipelineLog.log("acceptance-passed-through", fields: [
                    "action=\(action.debugName)",
                    "reason=\(block.reason)",
                    "context=\(SuggestionPipelineLog.contextDescription(liveContext))",
                    "current=\(SuggestionPipelineLog.suggestionDescription(currentSuggestion))"
                ])
                guardrailLogger.info("guardrail event=accept-block action=hide reason=\(block.reason) actionKind=\(action.debugName)")
                hideSuggestion(reason: "acceptance-\(block.reason)", context: liveContext)
                return nil
            }
            currentContext = liveContext
            return liveContext
        case .passedThrough(let reason):
            currentContext = liveContext
            statusMessage = "Suggestion unavailable"
            GeometryDebug.log("acceptance passed-through action=\(action.debugName) reason=\(reason.rawValue) context=\(debugContext(liveContext)) current=\(debugSuggestionState())")
            SuggestionPipelineLog.log("acceptance-passed-through", fields: [
                "action=\(action.debugName)",
                "reason=\(reason.rawValue)",
                "context=\(SuggestionPipelineLog.contextDescription(liveContext))",
                "current=\(SuggestionPipelineLog.suggestionDescription(currentSuggestion))"
            ])
            hideSuggestion(reason: "acceptance-\(reason.rawValue)", context: liveContext)
            if action == .fullSuggestion,
               reason != .noSuggestion,
               reason != .unexpectedSelection {
                predictionController.cancelAll()
                requestCompletion(for: liveContext, invocation: .manual)
                statusMessage = "Refreshing suggestion"
            }
            return nil
        }
    }

    private func validateGuardrailedAcceptance(
        context: TextContext,
        action: AcceptanceCommandAction
    ) -> AcceptanceSessionValidationResult {
        let sessionValidation = acceptanceSessionController.validateAcceptance(
            context: context,
            currentSuggestion: currentSuggestion
        )
        guard sessionValidation == .valid else {
            return sessionValidation
        }
        if currentSuggestion?.acceptedPrefix.isEmpty == false {
            return .valid
        }

        let currentFingerprint = SuggestionContextFingerprint.from(textContext: context)
        let decision = SuggestionGuardrailValidator.default.validateAccept(
            binding: currentSuggestion?.binding,
            currentStableFieldIdentity: context.stableFieldIdentity,
            currentFocusedElementID: context.focusedElementID,
            currentContextFingerprint: currentFingerprint
        )

        switch decision {
        case .allowAccept:
            return .valid
        case .blockAndHide(let reason):
            GeometryDebug.log("acceptance guardrail=block-hide action=\(action.debugName) reason=\(reason.rawValue) context=\(debugContext(context)) current=\(debugSuggestionState())")
            SuggestionPipelineLog.log("acceptance-guardrail", fields: [
                "action=\(action.debugName)",
                "decision=block-hide",
                "reason=\(reason.rawValue)",
                "context=\(SuggestionPipelineLog.contextDescription(context))",
                "current=\(SuggestionPipelineLog.suggestionDescription(currentSuggestion))"
            ])
            guardrailLogger.info("guardrail event=accept-block action=hide reason=\(reason.rawValue) actionKind=\(action.debugName)")
            hideSuggestion(reason: "acceptance-guardrail-\(reason.rawValue)", context: context)
            statusMessage = "Suggestion unavailable"
            return .passedThrough(.staleSuggestion)
        case .blockAndRegenerate(let reason):
            GeometryDebug.log("acceptance guardrail=block-regenerate action=\(action.debugName) reason=\(reason.rawValue) context=\(debugContext(context)) current=\(debugSuggestionState())")
            SuggestionPipelineLog.log("acceptance-guardrail", fields: [
                "action=\(action.debugName)",
                "decision=block-regenerate",
                "reason=\(reason.rawValue)",
                "context=\(SuggestionPipelineLog.contextDescription(context))",
                "current=\(SuggestionPipelineLog.suggestionDescription(currentSuggestion))"
            ])
            guardrailLogger.info("guardrail event=accept-block action=regenerate reason=\(reason.rawValue) actionKind=\(action.debugName)")
            hideSuggestion(reason: "acceptance-guardrail-\(reason.rawValue)", context: context)

            // Immediately regenerate for the current live context without relying on automatic eligibility.
            currentContext = context
            predictionController.cancelAll()
            requestCompletion(for: context, invocation: .manual)

            statusMessage = "Refreshing suggestion"
            return .passedThrough(.staleSuggestion)
        case .blockAndNoop(let reason):
            GeometryDebug.log("acceptance guardrail=block-noop action=\(action.debugName) reason=\(reason.rawValue) context=\(debugContext(context)) current=\(debugSuggestionState())")
            SuggestionPipelineLog.log("acceptance-guardrail", fields: [
                "action=\(action.debugName)",
                "decision=block-noop",
                "reason=\(reason.rawValue)",
                "context=\(SuggestionPipelineLog.contextDescription(context))",
                "current=\(SuggestionPipelineLog.suggestionDescription(currentSuggestion))"
            ])
            guardrailLogger.info("guardrail event=accept-block action=noop reason=\(reason.rawValue) actionKind=\(action.debugName)")
            statusMessage = "Suggestion unavailable"
            return .passedThrough(.staleSuggestion)
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

    private func schedulePostAcceptanceRefresh(
        for action: AcceptanceCommandAction,
        baseline: TextContext
    ) {
        postAcceptanceRefreshTask?.cancel()
        lifecycleController.beginAdaptiveFallbackBurst()
        postAcceptanceRefreshTask = Task { @MainActor [weak self] in
            await self?.awaitHostPublishThenRefresh(
                source: .postAcceptance(action),
                baseline: baseline,
                refreshOnTimeout: true
            )
        }
        GeometryDebug.log("acceptance-refresh scheduled action=\(action.debugName) hostPublishMaxMs=400")
    }

    private func shouldAwaitHostPublish(for action: SuggestionInputAction) -> Bool {
        switch action.event.eventKind {
        case .textMutation:
            return action.shouldSchedulePrediction
        case .shortcutMutation:
            return action.event.mayPublishHostText
        case .acceptance, .fullAcceptance, .manualTrigger, .dismissal, .navigation, .other:
            return action.shouldSchedulePrediction
        }
    }

    private func shouldCancelHostPublish(for action: SuggestionInputAction) -> Bool {
        switch action.event.eventKind {
        case .textMutation:
            return action.shouldClearSuggestion
        case .dismissal:
            return true
        case .navigation:
            return false
        case .shortcutMutation:
            return action.event.mayPublishHostText
        case .acceptance, .fullAcceptance, .manualTrigger, .other:
            return false
        }
    }

    private func shouldClearSuggestion(for action: SuggestionInputAction) -> Bool {
        switch action.event.eventKind {
        case .navigation where isNavigationClearSuppressed:
            GeometryDebug.log("input-navigation-clear suppressed reason=recent-text-mutation kind=\(action.event.debugName)")
            return false
        case .shortcutMutation:
            return action.event.mayPublishHostText
        case .textMutation, .navigation, .dismissal, .acceptance, .fullAcceptance, .manualTrigger, .other:
            return action.shouldClearSuggestion
        }
    }

    private var isNavigationClearSuppressed: Bool {
        Date() <= navigationClearSuppressedUntil
    }

    private func updateNavigationClearSuppression(for action: SuggestionInputAction) {
        switch action.event.eventKind {
        case .textMutation:
            if action.event.mayPublishHostText {
                navigationClearSuppressedUntil = Date().addingTimeInterval(navigationClearSuppressionInterval)
            }
        case .shortcutMutation:
            if action.event.mayPublishHostText {
                navigationClearSuppressedUntil = Date().addingTimeInterval(navigationClearSuppressionInterval)
            }
        case .acceptance, .fullAcceptance, .manualTrigger, .dismissal, .navigation, .other:
            break
        }
    }

    private func awaitHostPublishThenRefresh(
        source: SuggestionRefreshSource,
        baseline: TextContext?,
        refreshOnTimeout: Bool
    ) async {
        guard isAutocompleteEnabled, !isInteractionPipelineSuspended else {
            if isInteractionPipelineSuspended {
                GeometryDebug.log("host-publish skipped reason=pipeline-suspended source=\(source.debugName)")
            }
            return
        }

        let result = await hostPublishAwaiter.awaitPublication(
            after: baseline,
            provider: focusProvider,
            reason: source.debugName
        )

        switch result.outcome {
        case .ready:
            GeometryDebug.log("host-publish ready source=\(source.debugName) elapsedMs=\(result.elapsedMs)")
            requestRefresh(source: source)
        case .timeout:
            GeometryDebug.log("host-publish timeout source=\(source.debugName) elapsedMs=\(result.elapsedMs) refresh=\(refreshOnTimeout)")
            if refreshOnTimeout {
                requestRefresh(source: source)
            }
        case .cancelled:
            GeometryDebug.log("host-publish cancelled source=\(source.debugName) elapsedMs=\(result.elapsedMs)")
        }
    }

    private func requestRefresh(source: SuggestionRefreshSource) {
        guard !isInteractionPipelineSuspended else {
            RefreshDiagnostics.log("refresh-request skipped reason=pipeline-suspended source=\(source.debugName)")
            return
        }

        let queuedDebugName = refreshQueuedSource?.debugName ?? "nil"
        RefreshDiagnostics.log("refresh-request source=\(source.debugName) inFlight=\(refreshTask != nil) queued=\(queuedDebugName)")
        SuggestionPipelineLog.log("refresh-request", fields: [
            "source=\(source.debugName)",
            "inFlight=\(refreshTask != nil)",
            "queued=\(queuedDebugName)"
        ])

        // Single-flight: if a refresh is already running, remember we need another pass.
        if refreshTask != nil {
            // Coalesce: keep the most recent trigger as the queued source for diagnostics.
            refreshQueuedSource = source
            RefreshDiagnostics.log("refresh-queue source=\(source.debugName) running=true")
            SuggestionPipelineLog.log("refresh-queued", fields: [
                "source=\(source.debugName)"
            ])
            return
        }

        refreshTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            await self.performRefreshSingleFlight(initialSource: source)
        }
    }

    private func performRefreshSingleFlight(initialSource: SuggestionRefreshSource) async {
        var sourceToRun = initialSource

        while true {
            guard !isInteractionPipelineSuspended else {
                refreshTask = nil
                refreshQueuedSource = nil
                RefreshDiagnostics.log("refresh-single-flight stopped reason=pipeline-suspended source=\(sourceToRun.debugName)")
                return
            }

            await refresh(source: sourceToRun)

            if let queued = refreshQueuedSource {
                refreshQueuedSource = nil
                sourceToRun = queued
                RefreshDiagnostics.log("refresh-dequeue source=\(queued.debugName) followup=true")
                SuggestionPipelineLog.log("refresh-dequeued", fields: [
                    "source=\(queued.debugName)"
                ])
                continue
            }

            refreshTask = nil
            break
        }
    }

    private func refresh(source: SuggestionRefreshSource) async {
        guard isAutocompleteEnabled, !isInteractionPipelineSuspended else {
            if isInteractionPipelineSuspended {
                RefreshDiagnostics.log("refresh-skipped reason=pipeline-suspended source=\(source.debugName)")
            }
            return
        }

        let refreshStartedAt = ContinuousClock.now
        defer {
            let elapsed = elapsedMs(since: refreshStartedAt)
            RefreshDiagnostics.log("refresh-end source=\(source.debugName) elapsedMs=\(elapsed) status=\(statusMessage)")
            SuggestionPipelineLog.log("refresh-end", fields: [
                "source=\(source.debugName)",
                "elapsedMs=\(elapsed)",
                "status=\(SuggestionPipelineLog.privacySafeTextSummary(statusMessage))"
            ])
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
            RefreshDiagnostics.log("refresh-start source=\(source.debugName) app=\(context.app.bundleID)")
            prepareVisualContextIfNeeded(for: context, source: source)
            SuggestionPipelineLog.log("refresh-context", fields: [
                "source=\(source.debugName)",
                "context=\(SuggestionPipelineLog.contextDescription(context))",
                "previous=\(SuggestionPipelineLog.contextDescription(currentContext))",
                "current=\(SuggestionPipelineLog.suggestionDescription(currentSuggestion))"
            ])

            if handleAppSwitchIfNeeded(context: context, source: source) {
                GeometryDebug.log("refresh-branch action=app-switch source=\(source.debugName) context=\(debugContext(context))")
                SuggestionPipelineLog.log("refresh-branch", fields: [
                    "action=app-switch",
                    "source=\(source.debugName)",
                    "context=\(SuggestionPipelineLog.contextDescription(context))"
                ])
                return
            }

            if dismissalStillApplies(to: context) {
                currentContext = context
                predictionController.cancelAll()
                currentSuggestion = nil
                statusMessage = "Suggestion dismissed"
                presenter.hide()
                GeometryDebug.log("refresh-branch action=dismissed-until-mutation context=\(debugContext(context))")
                SuggestionPipelineLog.log("refresh-branch", fields: [
                    "action=dismissed-until-mutation",
                    "context=\(SuggestionPipelineLog.contextDescription(context))"
                ])
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
                SuggestionPipelineLog.log("refresh-branch", fields: [
                    "action=empty-context",
                    "decision=\(debugEligibilityDecision(decision))",
                    "context=\(SuggestionPipelineLog.contextDescription(context))"
                ])
                applyIneligibleDecision(decision, context: context)
                return
            }

            if await repairLeakedShortcutIfNeeded(context) {
                GeometryDebug.log("refresh-branch action=shortcut-repair")
                SuggestionPipelineLog.log("refresh-branch", fields: [
                    "action=shortcut-repair",
                    "context=\(SuggestionPipelineLog.contextDescription(context))",
                    "current=\(SuggestionPipelineLog.suggestionDescription(currentSuggestion))"
                ])
                return
            }

            if repairCompletedAcceptAllLeakIfNeeded(context) {
                GeometryDebug.log("refresh-branch action=completed-accept-all-repair")
                SuggestionPipelineLog.log("refresh-branch", fields: [
                    "action=completed-accept-all-repair",
                    "context=\(SuggestionPipelineLog.contextDescription(context))"
                ])
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
                SuggestionPipelineLog.log("suggestion-keep", fields: [
                    "reason=web-whitespace-normalization",
                    "context=\(SuggestionPipelineLog.contextDescription(context))",
                    "previous=\(SuggestionPipelineLog.contextDescription(previousContext))",
                    "current=\(SuggestionPipelineLog.suggestionDescription(suggestion))"
                ])
                presenter.update(suggestion, for: presentationContext, mode: displayMode(for: presentationContext))
                return
            }

            if handleAcceptedSuggestionSession(context) {
                GeometryDebug.log("refresh-branch action=accepted-session")
                SuggestionPipelineLog.log("refresh-branch", fields: [
                    "action=accepted-session",
                    "context=\(SuggestionPipelineLog.contextDescription(context))",
                    "current=\(SuggestionPipelineLog.suggestionDescription(currentSuggestion))"
                ])
                return
            }

            if let suggestion = currentSuggestion,
               !suggestion.isExhausted,
               let previousContext = currentContext,
               isSameFocusedText(context, as: previousContext) {
                currentContext = context
                GeometryDebug.log("suggestion-keep reason=same-focused-text context=\(debugContext(context)) current=\(debugSuggestionState(suggestion))")
                SuggestionPipelineLog.log("suggestion-keep", fields: [
                    "reason=same-focused-text",
                    "context=\(SuggestionPipelineLog.contextDescription(context))",
                    "current=\(SuggestionPipelineLog.suggestionDescription(suggestion))"
                ])
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
                SuggestionPipelineLog.log("suggestion-keep", fields: [
                    "reason=accepted-prefix-consistent",
                    "context=\(SuggestionPipelineLog.contextDescription(context))",
                    "previous=\(SuggestionPipelineLog.contextDescription(prevContext))",
                    "current=\(SuggestionPipelineLog.suggestionDescription(suggestion))"
                ])
                presenter.update(suggestion, for: context, mode: displayMode(for: context))
                return
            }

            let previousObservedContext = currentContext
            let eligibilityDecision = eligibilityDecision(
                for: context,
                previousObservedContext: previousObservedContext,
                inputMethodState: inputMethodState
            )
            let shouldPreserveEligibilityDiagnostics = eligibilityDecision.skipReason == .unchangedContext
                && currentSuggestion == nil
            if !shouldPreserveEligibilityDiagnostics {
                diagnostics.recordEligibility(eligibilityDecision)
                logEligibilityDecision(eligibilityDecision)
            }
            GeometryDebug.log("refresh-branch action=eligibility source=\(source.debugName) decision=\(debugEligibilityDecision(eligibilityDecision)) context=\(debugContext(context)) previous=\(debugContext(previousObservedContext)) current=\(debugSuggestionState())")
            SuggestionPipelineLog.log("refresh-eligibility", fields: [
                "source=\(source.debugName)",
                "decision=\(debugEligibilityDecision(eligibilityDecision))",
                "context=\(SuggestionPipelineLog.contextDescription(context))",
                "previous=\(SuggestionPipelineLog.contextDescription(previousObservedContext))",
                "current=\(SuggestionPipelineLog.suggestionDescription(currentSuggestion))"
            ])
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
            inputController.clearSuggestionTrigger()
            let debounceInterval = predictionController.debounceInterval
            let debounceStartedAt = ContinuousClock.now
            let debounceWorkID = predictionController.replaceDebouncedWork { [weak self, debounceInterval, latencySeed, debounceStartedAt] workID in
                try? await Task.sleep(nanoseconds: UInt64(debounceInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                guard let engine = self else { return }
                await MainActor.run {
                    guard engine.predictionController.isCurrent(workID) else {
                        GeometryDebug.log("completion-debounce skipped reason=stale-work workID=\(workID) generation=\(workID) source=\(source.debugName) context=\(engine.debugContext(context))")
                        SuggestionPipelineLog.log("completion-debounce-skipped", fields: [
                            "reason=stale-work",
                            "workID=\(workID)",
                            "source=\(source.debugName)",
                            "context=\(SuggestionPipelineLog.contextDescription(context))"
                        ])
                        return
                    }
                    GeometryDebug.log("completion-debounce fired workID=\(workID) generation=\(workID) source=\(source.debugName) context=\(engine.debugContext(context))")
                    SuggestionPipelineLog.log("completion-debounce-fired", fields: [
                        "workID=\(workID)",
                        "source=\(source.debugName)",
                        "context=\(SuggestionPipelineLog.contextDescription(context))"
                    ])
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
            SuggestionPipelineLog.log("completion-debounce-scheduled", fields: [
                "workID=\(debounceWorkID)",
                "source=\(source.debugName)",
                "intervalMs=\(Int(debounceInterval * 1000))",
                "context=\(SuggestionPipelineLog.contextDescription(context))"
            ])
        } catch {
            keystrokeBufferFallback?.observeFocusFailure(error)
            diagnostics.recordFocusFailure(error)
            if preserveSuggestionAcrossTransientFocusFailure(error) {
                return
            }

            currentContext = nil
            currentSuggestion = nil
            clearVisualContextOnFocusFailure(error)
            statusMessage = (error as? LocalizedError)?.errorDescription ?? "No compatible text field"
            GeometryDebug.log("refresh-error status=\(statusMessage)")
            SuggestionPipelineLog.log("refresh-context-failed", fields: [
                "source=\(source.debugName)",
                "error=\(SuggestionPipelineLog.privacySafeErrorSummary(error))"
            ])
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
        case .navigation:
            hideSuggestion(reason: "input-\(action.event.eventKind.rawValue)", context: currentContext)
        case .shortcutMutation:
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

    private func prepareVisualContextIfNeeded(for context: TextContext, source: SuggestionRefreshSource) {
        guard let sessionController = visualContextProvider as? VisualContextSessionControlling else {
            return
        }

        guard shouldPrepareVisualContext(for: context) else {
            sessionController.stopAndClear()
            return
        }

        switch source {
        case .focusChanged, .activeAppChanged:
            sessionController.refreshOnFocusOrWindowChange(context)
        case .startup:
            sessionController.startIfEligible(for: context)
        case .inputEvent, .acceptanceGuardrail, .postAcceptance, .shortcutLeakRepair, .fallbackTimer:
            break
        }
    }

    private func shouldPrepareVisualContext(for context: TextContext) -> Bool {
        guard isAutocompleteEnabled,
              !isInteractionPipelineSuspended,
              !isLowTrustContext(context),
              privacyStore.load().screenContextEnabled else {
            return false
        }

        let compatibilityDecision = compatibilityCatalog.decision(
            bundleID: context.app.bundleID,
            domain: context.domain,
            userModeOverrides: compatibilitySettings.loadModeOverrides()
        )
        guard compatibilityDecision.enabled,
              compatibilityDecision.mode != .disabled else {
            return false
        }

        return domainRuleEligibilitySkipReason(for: context, invocation: .automatic) != .domainDenied
    }

    private func clearVisualContextOnFocusFailure(_ error: Error) {
        guard let contextError = error as? AXTextContextError else {
            return
        }

        switch contextError {
        case .secureOrUnsupportedField, .accessibilityNotTrusted, .noFrontmostApplication, .interactionPipelineSuspended:
            (visualContextProvider as? VisualContextSessionControlling)?.stopAndClear()
        case .noReadableText, .noFocusedElement:
            break
        }
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

        // Domain / web-app rules are enforced here for browser contexts.
        if let skipReason = domainRuleEligibilitySkipReason(for: context, invocation: invocation) {
            diagnostics.recordDomainRuleDecision(skipReason, domainResolution: domainResolution(for: context))
            return SuggestionEligibilityDecision(
                outcome: .ineligible(skipReason),
                statusMessage: nil,
                logs: []
            )
        }

        // Enforce visual-context-required rule behavior:
        // if a domain requires visual context, do not activate autocomplete unless the
        // visual context pipeline is currently available and enabled.
        if invocation != .manual,
           domainRuleEligibilitySkipReason(for: context, invocation: invocation) == nil,
           domainRuleRequiresVisualContext(for: context),
           !visualContextEligibilitySatisfied(for: context) {
            diagnostics.recordDomainRuleDecision(.domainNeedsVisualContext, domainResolution: domainResolution(for: context))
            return SuggestionEligibilityDecision(
                outcome: .ineligible(.domainNeedsVisualContext),
                statusMessage: "Visual context required",
                logs: []
            )
        }

        return eligibilityEvaluator.evaluate(
            context: context,
            previousContext: previousObservedContext,
            compatibilityDecision: compatibilityDecision,
            lastSuggestionTriggerKeyAt: inputController.lastSuggestionTriggerKeyAt,
            invocation: invocation,
            inputMethodState: inputMethodState
        )
    }

    private func domainRuleRequiresVisualContext(for context: TextContext) -> Bool {
        // Conservative host-only matching; only applies when we have a domain string.
        guard let domain = context.domain?.trimmingCharacters(in: .whitespacesAndNewlines),
              !domain.isEmpty else {
            return false
        }

        let canonical = DomainNormalization.canonicalDomainString(from: domain)

        // Today, treat spreadsheet/presentation editors as requiring visual context in order to run
        // in automatic mode. Google Docs itself remains governed by the compatibility catalog.
        return canonical == "sheets.google.com"
            || canonical == "slides.google.com"
    }

    private func visualContextEligibilitySatisfied(for context: TextContext) -> Bool {
        // Visual context is satisfied when:
        // - a visual context provider exists, AND
        // - privacy settings enable screen context, AND
        // - screen recording permission is available, AND
        // - a cache entry is already ready for the focused target.
        //
        // Capture runs out-of-band; this gate prevents required-visual domains from
        // falling back to a prompt without the cache.
        guard let coordinator = visualContextProvider as? VisualContextCoordinator else {
            return false
        }

        let settings = privacyStore.load()
        guard settings.screenContextEnabled else {
            return false
        }

        guard coordinator.canAttemptCapture,
              let session = coordinator.currentSession(),
              session.state == .ready,
              let snapshot = session.snapshot,
              !snapshot.isEmpty else {
            return false
        }

        guard let visualIdentity = snapshot.stableFieldIdentity else {
            return true
        }
        guard let contextIdentity = context.stableFieldIdentity else {
            return false
        }
        return visualIdentity.matchesStableTarget(contextIdentity)
    }

    private func domainRuleEligibilitySkipReason(
        for context: TextContext,
        invocation: SuggestionEligibilityInvocation
    ) -> SuggestionEligibilitySkipReason? {
        // Keep this conservative: only apply to contexts where we have a host-only domain.
        // (AppIdentity currently does not expose a reliable "isBrowser" signal in this worktree.)

        guard let domain = context.domain?.trimmingCharacters(in: .whitespacesAndNewlines),
              !domain.isEmpty else {
            return nil
        }

        // Compatibility overrides still apply; this is additional gating.
        // For now, treat a small set of sensitive web apps as denied.
        let canonical = DomainNormalization.canonicalDomainString(from: domain)

        // Email web apps are denied by default (users can later override via rule UI).
        if canonical == "mail.google.com" || canonical == "outlook.office.com" || canonical == "outlook.live.com" {
            return .domainDenied
        }

        // Spreadsheet/presentation editors are manual-only unless invoked manually.
        if invocation != .manual {
            if canonical == "sheets.google.com" || canonical == "slides.google.com" {
                return .domainManualOnly
            }
        }

        return nil
    }

    private func applyIneligibleDecision(
        _ decision: SuggestionEligibilityDecision,
        context: TextContext
    ) {
        GeometryDebug.log("ineligible-apply decision=\(debugEligibilityDecision(decision)) context=\(debugContext(context)) current=\(debugSuggestionState())")
        SuggestionPipelineLog.log("ineligible-apply", fields: [
            "decision=\(debugEligibilityDecision(decision))",
            "statusSet=\(decision.statusMessage != nil)",
            "context=\(SuggestionPipelineLog.contextDescription(context))",
            "current=\(SuggestionPipelineLog.suggestionDescription(currentSuggestion))"
        ])
        if let statusMessage = decision.statusMessage {
            self.statusMessage = statusMessage
        }

        switch decision.skipReason {
        case .emptyContext:
            currentContext = context
            predictionController.cancelAll()
            hideSuggestion(reason: "empty-context", context: context)
        case .compatibility, .manualOnlyWaitingForTrigger, .sentenceComplete, .domainDenied:
            hideSuggestion(reason: decision.skipReason?.rawValue ?? "ineligible", context: context)
        case .domainManualOnly, .domainNeedsVisualContext:
            // Treat these similarly to other "waiting" states.
            currentContext = context
            predictionController.cancelAll()
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

    private func personalizationPromptSamples(
        for context: TextContext,
        privacySettings: PrivacySettings
    ) -> [PersonalizationSample] {
        guard let personalizationRecorder else {
            return []
        }

        let samples = personalizationRecorder.promptSamples(
            for: context,
            privacySettings: privacySettings
        )
        personalizationRecorder.recordSample(from: context, privacySettings: privacySettings)
        return samples
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

    private func recordGeneratedSuggestion() {
        (productivityMetrics as? CompletionTelemetryMetricsRecording)?.recordGeneratedSuggestion()
    }

    private func recordShownSuggestion() {
        (productivityMetrics as? CompletionTelemetryMetricsRecording)?.recordShownSuggestion()
    }

    private func recordSuppressedSuggestion(reason: String) {
        (productivityMetrics as? CompletionTelemetryMetricsRecording)?.recordSuppressedSuggestion(reason: reason)
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
        guard !isInteractionPipelineSuspended else {
            GeometryDebug.log("completion-suppressed reason=pipeline-suspended context=\(debugContext(context))")
            statusMessage = "AutoComp paused"
            recordSuppressedSuggestion(reason: "pipeline-suspended")
            hideSuggestion(reason: "pipeline-suspended", context: context)
            return
        }

        backendStatusSummary = backendHealthMonitor.refresh()
        SuggestionPipelineLog.log("completion-request", fields: [
            "invocation=\(invocation.debugName)",
            "routing=\(SuggestionPipelineLog.routingDescription(routingPolicy()))",
            "context=\(SuggestionPipelineLog.contextDescription(context))"
        ])
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
            recordSuppressedSuggestion(reason: "backend-paused")
            SuggestionPipelineLog.log("completion-suppressed", fields: [
                "reason=backend-paused",
                "issue=\(suppression.issue?.logValue ?? "unknown")",
                "remainingSeconds=\(remainingSeconds)",
                "context=\(SuggestionPipelineLog.contextDescription(context))"
            ])
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

        diagnostics.recordBackendRequest(policy: routingPolicy())
        let requestedSignature = contextGenerationTracker.signature(for: context)
        let providerGeneration = providerLifecycleGeneration
        let latencyStartedAt = latencySeed?.startedAt ?? ContinuousClock.now
        let initialLatencyReport = completionLatencyReport(from: latencySeed)
        predictionController.replaceGenerationWork { [weak self] workID in
            GeometryDebug.log("completion-request workID=\(workID) generation=\(workID) app=\(context.app.displayName) bundle=\(context.app.bundleID) context=\(context.geometryDebugDescription)")
            SuggestionPipelineLog.log("completion-start", fields: [
                "workID=\(workID)",
                "invocation=\(invocation.debugName)",
                "context=\(SuggestionPipelineLog.contextDescription(context))"
            ])
            guard let engine = self else { return }
            guard !Task.isCancelled else {
                await MainActor.run {
                    SuggestionPipelineLog.log("completion-cancelled", fields: [
                        "workID=\(workID)",
                        "reason=task-cancelled-before-start",
                        "context=\(SuggestionPipelineLog.contextDescription(context))"
                    ])
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
            var latencyReport = initialLatencyReport
                let privacySettings = engine.privacyStore.load()
                let personalizationSamples = await MainActor.run {
                    engine.personalizationPromptSamples(
                        for: context,
                        privacySettings: privacySettings
                    )
                }
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
                        SuggestionPipelineLog.log("completion-cancelled", fields: [
                            "workID=\(workID)",
                            "reason=task-cancelled-before-provider",
                            "visualContext=\(visualContext == nil ? "none" : "included")",
                            "context=\(SuggestionPipelineLog.contextDescription(context))"
                        ])
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
                        SuggestionPipelineLog.log("completion-discarded", fields: [
                            "workID=\(workID)",
                            "reason=backend-switch-before-provider",
                            "context=\(SuggestionPipelineLog.contextDescription(context))"
                        ])
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
                            SuggestionPipelineLog.log("completion-discarded", fields: [
                                "workID=\(workID)",
                                "reason=missing-live-context-after-visual",
                                "context=\(SuggestionPipelineLog.contextDescription(context))"
                            ])
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
                            SuggestionPipelineLog.log("completion-discarded", fields: [
                                "workID=\(workID)",
                                "reason=stale-visual-context",
                                "requested=\(SuggestionPipelineLog.contextDescription(context))",
                                "live=\(SuggestionPipelineLog.contextDescription(liveContextAfterVisual))"
                            ])
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
                    SuggestionPipelineLog.log("completion-context-ready", fields: [
                        "workID=\(workID)",
                        "visualContext=\(ContextCaptureDiagnostics(context: context, visualContext: visualContext, clipboardContext: clipboardContext).visualContextLogValue)",
                        "clipboardContext=\(ContextCaptureDiagnostics(context: context, visualContext: visualContext, clipboardContext: clipboardContext).clipboardContextLogValue)",
                        "context=\(SuggestionPipelineLog.contextDescription(context))"
                    ])
                }

                // Provider invocation is delegated to the pipeline runner, with cancellation/stale-work
                // checks extracted into reusable steps.
                var pipelineContext = SuggestionPipeline.RequestContext()
                pipelineContext.userInfo["context"] = context
                pipelineContext.userInfo["privacySettings"] = privacySettings
                pipelineContext.userInfo["visualContext"] = visualContext
                pipelineContext.userInfo["clipboardContext"] = clipboardContext
                pipelineContext.userInfo["personalizationSamples"] = personalizationSamples

                let (isCurrentAfterVisual, provider, completionOptions) = await MainActor.run {
                    (
                        engine.predictionController.isCurrent(workID),
                        engine.generationProvider,
                        CompletionOptions(
                            suggestionCount: engine.shouldRequestMultipleSuggestions(for: context, invocation: invocation) ? 3 : 1
                        )
                    )
                }
                await MainActor.run {
                    SuggestionPipelineLog.log("provider-start", fields: [
                        "workID=\(workID)",
                        "current=\(isCurrentAfterVisual)",
                        "routing=\(SuggestionPipelineLog.routingDescription(engine.routingPolicy()))",
                        "suggestionCount=\(completionOptions.suggestionCount)",
                        "context=\(SuggestionPipelineLog.contextDescription(context))"
                    ])
                }
                let runner = SuggestionPipeline.Runner<Suggestion>(steps: [
                    SuggestionPipeline.StaleWorkStep<Suggestion>(isCurrent: { _ in
                        isCurrentAfterVisual
                    }),
                    ProviderInvocationStep(
                        provider: provider,
                        timeout: nil,
                        requestProvider: { ctx in
                            guard let context = ctx.userInfo["context"] as? TextContext,
                                  let privacySettings = ctx.userInfo["privacySettings"] as? PrivacySettings else {
                                return nil
                            }
                            return ProviderInvocation.Request(
                                context: context,
                                privacySettings: privacySettings,
                                visualContext: ctx.userInfo["visualContext"] as? VisualContextSnapshot,
                                clipboardContext: ctx.userInfo["clipboardContext"] as? ClipboardContextSnapshot,
                                personalizationSamples: ctx.userInfo["personalizationSamples"] as? [PersonalizationSample] ?? [],
                                options: completionOptions
                            )
                        }
                    )
                ])

                let backendStartedAt = ContinuousClock.now
                let pipelineOutcome = await runner.run(context: &pipelineContext)
                latencyReport.backendMs = backendStartedAt.duration(to: .now).appMilliseconds
                await MainActor.run {
                    SuggestionPipelineLog.log("provider-finished", fields: [
                        "workID=\(workID)",
                        "outcome=\(Self.pipelineOutcomeDescription(pipelineOutcome))",
                        "backendMs=\(latencyReport.backendMs ?? -1)",
                        "context=\(SuggestionPipelineLog.contextDescription(context))"
                    ])
                }

                let promptCacheStats = await engine.promptCacheStatsIfAvailable()

                switch pipelineOutcome {
                case .publish(let suggestion):
                    let completionLatencyReport = latencyReport
                    await MainActor.run {
                        if engine.predictionController.isCurrent(workID) {
                            engine.recordGeneratedSuggestion()
                        }
                    }
                    await MainActor.run {
                        guard engine.predictionController.isCurrent(workID) else {
                            return
                        }
                        engine.backendStatusSummary = engine.backendHealthMonitor.recordSuccess()

                        // Keep existing low-trust behavior: skip live revalidation.
                        if isLowTrustRequest {
                            GeometryDebug.log("completion-success revalidation=skipped-low-trust context=\(engine.debugContext(context)) suggestion=\(engine.debugSuggestionState(suggestion))")
                            SuggestionPipelineLog.log("completion-revalidation", fields: [
                                "workID=\(workID)",
                                "result=skipped-low-trust",
                                "context=\(SuggestionPipelineLog.contextDescription(context))",
                                "suggestion=\(SuggestionPipelineLog.suggestionDescription(suggestion))"
                            ])
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
                                suggestions: [suggestion]
                            )
                            engine.diagnostics.recordPromptCache(promptCacheStats)
                            return
                        }
                    }

                    if isLowTrustRequest {
                        return
                    }

                    // Preserve the existing live-context revalidation path.
                    let liveContext: TextContext
                    do {
                        liveContext = try await engine.focusProvider.currentContext()
                    } catch {
                        await MainActor.run {
                            guard engine.predictionController.isCurrent(workID) else {
                                return
                            }
                            GeometryDebug.log("completion-discarded reason=missing-live-context requested=\(engine.debugContext(context))")
                            SuggestionPipelineLog.log("completion-discarded", fields: [
                                "workID=\(workID)",
                                "reason=missing-live-context",
                                "context=\(SuggestionPipelineLog.contextDescription(context))",
                                "suggestion=\(SuggestionPipelineLog.suggestionDescription(suggestion))"
                            ])
                            engine.diagnostics.recordStaleDiscard(reason: "missing-live-context")
                            engine.recordAutocompleteDebug(
                                context: context,
                                privacySettings: privacySettings,
                                visualContext: visualContext,
                                clipboardContext: clipboardContext,
                                invocation: invocation,
                                outcome: "discarded",
                                suggestions: [suggestion],
                                discardReason: "missing-live-context"
                            )
                            engine.hideSuggestion(reason: "missing-live-context", context: context)
                        }
                        return
                    }

                    await MainActor.run {
                        guard engine.predictionController.isCurrent(workID) else {
                            GeometryDebug.log("completion-discarded reason=stale-work requested=\(engine.debugContext(context)) live=\(engine.debugContext(liveContext))")
                            SuggestionPipelineLog.log("completion-discarded", fields: [
                                "workID=\(workID)",
                                "reason=stale-work",
                                "requested=\(SuggestionPipelineLog.contextDescription(context))",
                                "live=\(SuggestionPipelineLog.contextDescription(liveContext))",
                                "suggestion=\(SuggestionPipelineLog.suggestionDescription(suggestion))"
                            ])
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
                                suggestions: [suggestion],
                                discardReason: "stale-work"
                            )
                            return
                        }

                        let liveContextMatchesRequest = engine.contextGenerationTracker.matches(liveContext, signature: requestedSignature)
                        engine.recordTrustedContext(liveContext)
                        GeometryDebug.log("completion-live-context match=\(liveContextMatchesRequest) requested=\(engine.debugContext(context)) live=\(engine.debugContext(liveContext))")
                        SuggestionPipelineLog.log("completion-revalidation", fields: [
                            "workID=\(workID)",
                            "match=\(liveContextMatchesRequest)",
                            "requested=\(SuggestionPipelineLog.contextDescription(context))",
                            "live=\(SuggestionPipelineLog.contextDescription(liveContext))",
                            "suggestion=\(SuggestionPipelineLog.suggestionDescription(suggestion))"
                        ])
                        guard liveContextMatchesRequest else {
                            GeometryDebug.log("completion-discarded reason=stale-context requested=\(engine.debugContext(context)) live=\(engine.debugContext(liveContext))")
                            SuggestionPipelineLog.log("completion-discarded", fields: [
                                "workID=\(workID)",
                                "reason=stale-context",
                                "requested=\(SuggestionPipelineLog.contextDescription(context))",
                                "live=\(SuggestionPipelineLog.contextDescription(liveContext))",
                                "suggestion=\(SuggestionPipelineLog.suggestionDescription(suggestion))"
                            ])
                            engine.diagnostics.recordStaleDiscard(reason: "stale-context")
                            engine.recordAutocompleteDebug(
                                context: context,
                                privacySettings: privacySettings,
                                visualContext: visualContext,
                                clipboardContext: clipboardContext,
                                invocation: invocation,
                                outcome: "discarded",
                                suggestions: [suggestion],
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
                            suggestions: [suggestion]
                        )
                        engine.diagnostics.recordPromptCache(promptCacheStats)
                    }

                case .discard(let reason):
                    await MainActor.run {
                        guard engine.predictionController.isCurrent(workID) else { return }
                        GeometryDebug.log("completion-discarded reason=\(reason.message ?? reason.kind.rawValue) requested=\(engine.debugContext(context))")
                        engine.recordSuppressedSuggestion(reason: reason.message ?? reason.kind.rawValue)
                        SuggestionPipelineLog.log("completion-discarded", fields: [
                            "workID=\(workID)",
                            "reason=\(SuggestionPipelineLog.discardReasonDescription(reason))",
                            "context=\(SuggestionPipelineLog.contextDescription(context))"
                        ])
                        engine.recordAutocompleteDebug(
                            context: context,
                            privacySettings: privacySettings,
                            visualContext: visualContext,
                            clipboardContext: clipboardContext,
                            invocation: invocation,
                            outcome: "discarded",
                            discardReason: reason.message ?? reason.kind.rawValue
                        )
                        engine.hideSuggestion(reason: reason.message ?? reason.kind.rawValue, context: context)
                    }

                case .failure(let reason):
                    await MainActor.run {
                        guard engine.predictionController.isCurrent(workID) else { return }
                        let message = reason.backendIssue?.message ?? reason.message ?? "completion-failed"
                        let failureError = ProviderInvocationFailureError(message: message)
                        GeometryDebug.log("completion-failed context=\(engine.debugContext(context)) error=\(message)")
                        engine.recordSuppressedSuggestion(reason: reason.backendIssue?.logValue ?? reason.kind.rawValue)
                        SuggestionPipelineLog.log("completion-failed", fields: [
                            "workID=\(workID)",
                            "kind=\(reason.kind.rawValue)",
                            "issue=\(reason.backendIssue?.logValue ?? "unknown")",
                            "error=\(SuggestionPipelineLog.privacySafeTextSummary(message))",
                            "context=\(SuggestionPipelineLog.contextDescription(context))"
                        ])
                        engine.diagnostics.recordBackendFailure(message: message, kind: engine.routingPolicy()?.activeKind)
                        if let issue = reason.backendIssue {
                            let healthSummary = engine.backendHealthMonitor.recordFailure(issue: issue)
                            engine.backendStatusSummary = healthSummary
                            if healthSummary.state == .paused {
                                let remainingSeconds = healthSummary.remainingSuppressionSeconds() ?? 0
                                engine.statusMessage = healthSummary.statusMessage()
                                engine.diagnostics.recordBackendPaused(healthSummary)
                                GeometryDebug.log("completion-paused issue=\(healthSummary.issue?.logValue ?? "unknown") remainingSeconds=\(remainingSeconds) consecutiveFailures=\(engine.backendHealthMonitor.circuitBreaker.consecutiveFailures)")
                                SuggestionPipelineLog.log("completion-paused", fields: [
                                    "workID=\(workID)",
                                    "issue=\(healthSummary.issue?.logValue ?? "unknown")",
                                    "remainingSeconds=\(remainingSeconds)",
                                    "consecutiveFailures=\(engine.backendHealthMonitor.circuitBreaker.consecutiveFailures)"
                                ])
                            } else {
                                engine.statusMessage = message
                            }
                        } else {
                            engine.statusMessage = message
                        }
                        engine.recordAutocompleteDebug(
                            context: context,
                            privacySettings: privacySettings,
                            visualContext: visualContext,
                            clipboardContext: clipboardContext,
                            invocation: invocation,
                            outcome: "failed",
                            error: failureError
                        )
                        engine.hideSuggestion(reason: "completion-failed", context: context)
                    }

                case .continue:
                    break
                }
        }
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
        if let provider = generationProvider as? ClipboardContextAwareCompletionProvider {
            return [
                try await provider.complete(
                    context: context,
                    privacySettings: privacySettings,
                    visualContext: visualContext,
                    clipboardContext: clipboardContext
                )
            ]
        }
        if let provider = generationProvider as? VisualContextAwareCompletionProvider {
            return [
                try await provider.complete(
                    context: context,
                    privacySettings: privacySettings,
                    visualContext: visualContext
                )
            ]
        }
        return [
            try await generationProvider.complete(context: context)
        ]
    }

    nonisolated private static func pipelineOutcomeDescription(
        _ outcome: SuggestionPipeline.Outcome<Suggestion>
    ) -> String {
        switch outcome {
        case .continue:
            return "continue"
        case .discard(let reason):
            return "discard:\(SuggestionPipelineLog.discardReasonDescription(reason))"
        case .publish(let suggestion):
            return "publish:\(SuggestionPipelineLog.suggestionDescription(suggestion))"
        case .failure(let reason):
            return "failure:\(SuggestionPipelineLog.discardReasonDescription(reason))"
        }
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
        if let contextProvider = visualContextProvider as? TextContextVisualContextProvider {
            return await contextProvider.currentVisualContext(for: context)
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
            Task { @MainActor [weak self, context] in
                await self?.awaitHostPublishThenRefresh(
                    source: .shortcutLeakRepair,
                    baseline: context,
                    refreshOnTimeout: true
                )
            }

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
        case .accessibilityNotTrusted, .noFrontmostApplication, .secureOrUnsupportedField, .interactionPipelineSuspended:
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

        return isSameGoogleDocsVolatileLineTarget(
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

    private func isSameGoogleDocsVolatileLineTarget(
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

        return StableFieldIdentity.isGoogleDocsVolatileLineMetric(lhs)
            && StableFieldIdentity.isGoogleDocsVolatileLineMetric(rhs)
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
        SuggestionPipelineLog.log("publication-attempt", fields: [
            "mode=\(mode.rawValue)",
            "collectionAllowed=\(collectionAllowed)",
            "context=\(SuggestionPipelineLog.contextDescription(context))",
            "suggestion=\(SuggestionPipelineLog.suggestionDescription(suggestion))"
        ])
        let result = publicationController.publish(
            suggestion,
            context: context,
            displayMode: mode,
            collectionAllowed: collectionAllowed
        )
        logPublicationResult(result)
        SuggestionPipelineLog.log("publication-result", fields: [
            "outcome=\(publicationOutcomeDescription(result.outcome))",
            "normalizationMs=\(result.normalizationMs ?? -1)",
            "overlayMs=\(result.overlayMs ?? -1)",
            "context=\(SuggestionPipelineLog.contextDescription(context))"
        ])

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
            recordShownSuggestion()
            diagnostics.recordBackendSuccess(
                rawText: suggestion.rawText,
                normalizedText: suggestion.visibleText,
                collectionAllowed: collectionAllowed,
                route: suggestion.completionRoute
            )
            var boundSuggestion = suggestion
            boundSuggestion.binding = SuggestionBinding.from(textContext: context)

            currentSuggestion = boundSuggestion
            acceptanceSessionController.recordPublication(context: context, suggestion: boundSuggestion)
            GeometryDebug.log("suggestion-state action=published context=\(debugContext(context)) current=\(debugSuggestionState(boundSuggestion))")
            SuggestionPipelineLog.log("suggestion-state", fields: [
                "action=published",
                "context=\(SuggestionPipelineLog.contextDescription(context))",
                "current=\(SuggestionPipelineLog.suggestionDescription(boundSuggestion))"
            ])
            lastLatencyMs = result.lastLatencyMs
            if let statusMessage = result.statusMessage {
                self.statusMessage = statusMessage
            }
        case .rejected(let reason):
            recordSuppressedSuggestion(reason: "publication-\(reason.rawValue)")
            acceptanceSessionController.clearAll()
            currentSuggestion = nil
            GeometryDebug.log("suggestion-state action=rejected context=\(debugContext(context))")
            SuggestionPipelineLog.log("suggestion-state", fields: [
                "action=rejected",
                "context=\(SuggestionPipelineLog.contextDescription(context))"
            ])
        }

        return result
    }

    private func publicationOutcomeDescription(_ outcome: SuggestionPublicationOutcome) -> String {
        switch outcome {
        case .published(let suggestion):
            return "published:\(SuggestionPipelineLog.suggestionDescription(suggestion))"
        case .rejected(let reason):
            return "rejected:\(reason.rawValue)"
        }
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
        SuggestionPipelineLog.log("suggestion-hide", fields: [
            "reason=\(reason)",
            "context=\(SuggestionPipelineLog.contextDescription(context))",
            "current=\(SuggestionPipelineLog.suggestionDescription(currentSuggestion))"
        ])
        if reason.hasPrefix("acceptance-") || reason == "focus-changed" {
            guardrailLogger.info("guardrail event=suggestion-hide reason=\(reason)")
        }
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
