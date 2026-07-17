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

private struct SuggestionRefreshSchedulingEvidence: Equatable, Sendable {
    let hostPublishOutcome: SuggestionSchedulingHostPublishOutcome
    let hostPublishElapsedMs: Int
    let hostPublishPollCount: Int

    static let notAwaited = SuggestionRefreshSchedulingEvidence(
        hostPublishOutcome: .notAwaited,
        hostPublishElapsedMs: 0,
        hostPublishPollCount: 0
    )
}

private struct ProviderInvocationFailureError: LocalizedError {
    let message: String

    var errorDescription: String? {
        message
    }
}

@MainActor
private struct PendingPostAcceptanceCommand {
    let generation: UInt64
    let inserter: TextInserter
    let continuation: CheckedContinuation<SuggestionAcceptanceCommandOutcome, Never>
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

    var schedulingMutation: SuggestionSchedulingMutation {
        switch self {
        case .inputEvent(let event):
            switch event.eventKind {
            case .textMutation: return .insert
            case .shortcutMutation: return .shortcut
            case .acceptance, .fullAcceptance: return .acceptance
            case .manualTrigger, .dismissal, .navigation, .other: return .focusOrOther
            }
        case .postAcceptance:
            return .acceptance
        case .focusChanged, .activeAppChanged, .acceptanceGuardrail,
             .shortcutLeakRepair, .fallbackTimer, .startup:
            return .focusOrOther
        }
    }

    var reuseMutation: SuggestionReuseMutation {
        guard case .inputEvent(let event) = self else { return .other }
        if event.isDeletionMutation { return .delete }
        return event.eventKind == .textMutation ? .append : .other
    }

    var coalescingPriority: Int {
        switch self {
        case .inputEvent, .acceptanceGuardrail, .postAcceptance, .shortcutLeakRepair:
            return 3
        case .focusChanged, .activeAppChanged:
            return 2
        case .startup, .fallbackTimer:
            return 1
        }
    }
}

@MainActor
final class SuggestionEngine: ObservableObject {

    private let guardrailLogger = AutoCompLogger(category: "guardrails")

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
    private let eligibilityCoordinator: SuggestionEligibilityCoordinator
    private let completionRequestCoordinator = CompletionRequestCoordinator()
    private let inputMethodStateProvider: @Sendable () -> InputMethodState
    private let keystrokeBufferFallback: KeystrokeBufferFallback?
    private let publicationController: SuggestionPublicationController
    private let postProviderCoordinator = PostProviderCompletionCoordinator()
    private let acceptanceSessionController: AcceptanceSessionController
    private let acceptanceController: SuggestionAcceptanceController
    private let shortcutLeakRepairInserter: ShortcutLeakRepairing?
    private let emojiService = EmojiSuggestionService()
    private let lifecycleController = SuggestionLifecycleController()
    private let predictionController = SuggestionPredictionController()
    private let hostPublishAwaiter: HostPublishAwaiter
    private let schedulingPolicy: SuggestionSchedulingPolicy
    private var reuseStore: SuggestionReuseStore
    private let postAcceptanceSpeculationPolicy: PostAcceptanceSpeculationPolicy
    private let diagnosticsController = SuggestionDiagnosticsController()
    private let contextGenerationTracker = ContextGenerationTracker()
    private let suggestionDebugLogger: SuggestionDebugLogger?
    private let completionTraceRecorder: any CompletionTraceRecording
    private let debugOptionsProvider: @MainActor () -> AutoCompDebugOptions
    private let streamingConfiguration: StreamingCompletionConfiguration
    private let streamedSuggestionCoordinator = StreamedSuggestionCoordinator()

    private var providerLifecycleGeneration = 0
    private var dismissedContext: TextContext?
    private var postAcceptanceRefreshTask: Task<Void, Never>?
    private var postAcceptanceCommandTimeoutTask: Task<Void, Never>?
    private var postAcceptanceCommandBuffer = PostAcceptanceCommandBuffer()
    private var pendingPostAcceptanceCommand: PendingPostAcceptanceCommand?
    private var visualContextRefreshTask: Task<Void, Never>?

    // Refresh single-flight state: prevents overlapping refreshes and coalesces bursts.
    private var refreshTask: Task<Void, Never>?
    private var refreshQueuedSource: SuggestionRefreshSource?
    private var refreshQueuedTraceContext: CompletionTraceContext?
    private var refreshQueuedSchedulingEvidence: SuggestionRefreshSchedulingEvidence?
    private var finishedTraceIDs: Set<CompletionTraceID> = []

    private var backendLatencyHistory = SuggestionBackendLatencyHistory()
    private var lastTextMutationAt: Date?
    private var recentTypingIntervalMs: Int?

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
        schedulingPolicy: SuggestionSchedulingPolicy = SuggestionSchedulingPolicy(),
        reuseStore: SuggestionReuseStore = SuggestionReuseStore(),
        postAcceptanceSpeculationPolicy: PostAcceptanceSpeculationPolicy = PostAcceptanceSpeculationPolicy(),
        suggestionDebugLogger: SuggestionDebugLogger? = nil,
        completionTraceRecorder: any CompletionTraceRecording = NoopCompletionTraceRecorder(),
        streamingConfiguration: StreamingCompletionConfiguration = StreamingCompletionFeature.configuration(),
        debugOptionsProvider: @escaping @MainActor () -> AutoCompDebugOptions = { .normal }
    ) {
        self.focusProvider = contextProvider

        self.generationProvider = completionProvider
        self.backendHealthMonitor = backendHealthMonitor
        self.backendStatusSummary = backendHealthMonitor.summary
        self.visualContextProvider = visualContextProvider
        self.clipboardContextProvider = clipboardContextProvider
        self.keystrokeBufferFallback = keystrokeBufferFallback

        self.compatibilityCatalog = compatibilityCatalog
        self.compatibilitySettings = compatibilitySettings
        self.privacyStore = privacyStore
        self.personalizationRecorder = personalizationRecorder

        self.productivityMetrics = productivityMetrics
        self.suggestionDebugLogger = suggestionDebugLogger
        self.completionTraceRecorder = completionTraceRecorder
        self.streamingConfiguration = streamingConfiguration
        self.debugOptionsProvider = debugOptionsProvider

        self.presenter = presenter
        self.inputController = inputController
        self.isMultiSuggestionEnabled = multiSuggestionEnabled
        self.eligibilityCoordinator = SuggestionEligibilityCoordinator(evaluator: eligibilityEvaluator)
        self.inputMethodStateProvider = inputMethodStateProvider
        self.publicationController = publicationController ?? SuggestionPublicationController(presenter: presenter)
        self.acceptanceSessionController = acceptanceSessionController
        self.acceptanceController = SuggestionAcceptanceController(sessionController: acceptanceSessionController)
        self.shortcutLeakRepairInserter = shortcutLeakRepairInserter
        self.hostPublishAwaiter = hostPublishAwaiter
        self.schedulingPolicy = schedulingPolicy
        self.reuseStore = reuseStore
        self.postAcceptanceSpeculationPolicy = postAcceptanceSpeculationPolicy
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
            self?.closePostAcceptanceCommandWindow(reason: .focusChanged)
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
        refreshQueuedSchedulingEvidence = nil

        postAcceptanceRefreshTask?.cancel()
        postAcceptanceRefreshTask = nil
        closePostAcceptanceCommandWindow(reason: .teardown)
        acceptanceSessionController.clearAll()
        inputController.reset()
        reuseStore.reset()
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
            refreshQueuedTraceContext = nil
            refreshQueuedSchedulingEvidence = nil
            postAcceptanceRefreshTask?.cancel()
            postAcceptanceRefreshTask = nil
            closePostAcceptanceCommandWindow(reason: .teardown)
            dismissedContext = nil
            transientFocusFailureStartedAt = nil
            acceptanceSessionController.clearAll()
            inputController.reset()
            reuseStore.reset()
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
        closePostAcceptanceCommandWindow(reason: .teardown)
        acceptanceSessionController.clearAll()
        inputController.reset()
        reuseStore.reset()
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
        reuseStore.reset()
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
        if postAcceptanceCommandBuffer.shouldIntercept() {
            if inputMethodStateProvider().isComposingText {
                closePostAcceptanceCommandWindow(reason: .incompatibleInput)
                return .passThrough(reason: "ime-composition-active")
            }
            if command != .acceptNextWord {
                closePostAcceptanceCommandWindow(reason: .incompatibleInput)
            }
        }
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
        if action == .nextWord,
           postAcceptanceCommandBuffer.shouldIntercept() {
            return .consume(reason: postAcceptanceCommandBuffer.hasQueuedCommand
                ? "post-acceptance-command-already-buffered"
                : "post-acceptance-command-window")
        }

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

        if event != .tab, postAcceptanceCommandBuffer.shouldIntercept() {
            closePostAcceptanceCommandWindow(reason: .incompatibleInput)
        }

        let inputMethodState = inputMethodStateProvider()
        if event.eventKind == .textMutation {
            let now = Date()
            if let lastTextMutationAt {
                recentTypingIntervalMs = max(0, Int(now.timeIntervalSince(lastTextMutationAt) * 1_000))
            }
            lastTextMutationAt = now
        }
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

        // latest-request-wins starts at input observation, not after AX catches
        // up. This closes the window where an older debounce/provider could
        // fire while the newest key is still waiting for host publication.
        predictionController.cancelAll()
        hostPublishAwaiter.cancelAll(reason: "new-input-\(event.eventKind.rawValue)")

        if inputMethodState.isComposingText {
            statusMessage = "IME composition active"
            hideSuggestion(reason: "ime-composition-active", context: currentContext)
            GeometryDebug.log("input-event scheduling-suppressed reason=ime-composition-active")
            return
        }

        let traceContext = startCompletionTrace()
        recordTrace(
            traceContext,
            event: .inputObserved,
            reason: .automatic,
            outcome: .started
        )

        Task { @MainActor [weak self] in
            await self?.awaitHostPublishThenRefresh(
                source: .inputEvent(event),
                baseline: hostPublishBaseline,
                refreshOnTimeout: action.shouldSchedulePrediction || event.isDeletionMutation,
                traceContext: traceContext
            )
        }
    }

    func dismissSuggestionUntilTextMutation() {
        dismissedContext = currentContext
        statusMessage = "Suggestion dismissed"
        predictionController.cancelAll()
        hostPublishAwaiter.cancelAll(reason: "manual-dismiss")
        reuseStore.reset()
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
        let traceContext = startCompletionTrace()
        recordTrace(traceContext, event: .inputObserved, reason: .manual, outcome: .started)
        recordTrace(
            traceContext,
            event: .contextCaptured,
            outcome: .ready,
            prefixUTF16Length: (context.textBeforeCursor as NSString).length,
            suffixUTF16Length: context.textAfterCursor.map { ($0 as NSString).length } ?? 0
        )
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
        recordTrace(
            traceContext,
            event: .eligibilityDecided,
            outcome: decision.isEligible ? .allowed : .blocked
        )
        guard decision.isEligible else {
            applyIneligibleDecision(decision, context: context)
            finishTrace(traceContext, reason: .unknown, outcome: .discarded)
            return
        }

        dismissedContext = nil
        currentContext = context
        predictionController.cancelAll()
        hostPublishAwaiter.cancelAll(reason: "manual-trigger")
        acceptanceSessionController.clearAll()
        currentSuggestion = nil
        presenter.hide()
        requestCompletion(
            for: context,
            invocation: .manual,
            latencySeed: latencySeed,
            traceContext: traceContext
        )
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
        closePostAcceptanceCommandWindow(reason: .teardown)
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
        reuseStore.reset()
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

        if currentSuggestion == nil,
           postAcceptanceCommandBuffer.shouldIntercept() {
            return await enqueuePostAcceptanceCommand(using: inserter)
        }

        let action = AcceptanceCommandAction.nextWord
        let traceContext = currentSuggestion?.traceContext
        if let traceContext {
            recordTrace(traceContext, event: .acceptanceAttempted, outcome: .started)
        }
        guard let liveContext = await revalidatedAcceptanceContext(for: action) else {
            if let traceContext {
                recordTrace(
                    traceContext,
                    event: .acceptanceBlocked,
                    reason: .acceptanceBlocked,
                    outcome: .blocked
                )
                finishTrace(traceContext, reason: .acceptanceBlocked, outcome: .discarded)
            }
            return .passedThrough
        }
        let acceptingStreamedPartial = streamedSuggestionCoordinator.freezeForEarlyAcceptance(currentSuggestion)

        do {
            let insertionStartedAt = ContinuousClock.now
            guard let result = try await acceptanceController.acceptNextWord(
                currentSuggestion: currentSuggestion,
                currentContext: liveContext,
                using: inserter
            ) else {
                if acceptingStreamedPartial { streamedSuggestionCoordinator.resumeAfterFailedAcceptance() }
                GeometryDebug.log("acceptance passed-through action=\(action.debugName) reason=no-token context=\(debugContext(liveContext)) current=\(debugSuggestionState())")
                return .passedThrough
            }
            let insertionMs = elapsedMs(since: insertionStartedAt)
            if let traceContext {
                recordTrace(traceContext, event: .acceptanceAllowed, outcome: .allowed)
                recordTrace(
                    traceContext,
                    event: .acceptanceInserted,
                    outcome: .inserted,
                    durationMs: insertionMs
                )
                if result.currentSuggestion?.isExhausted ?? true {
                    recordTrace(traceContext, event: .sessionExhausted, reason: .exhausted, outcome: .exhausted)
                    finishTrace(traceContext, reason: .completed, outcome: .finished)
                } else {
                    recordTrace(traceContext, event: .sessionAdvanced, outcome: .advanced)
                }
            }
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
            if acceptingStreamedPartial {
                retireStreamAfterEarlyAcceptance(traceContext: traceContext)
                if var frozenSuggestion = currentSuggestion,
                   let streaming = frozenSuggestion.streamingMetadata {
                    frozenSuggestion.streamingMetadata = SuggestionStreamingMetadata(
                        traceID: streaming.traceID,
                        workID: streaming.workID,
                        providerSequence: streaming.providerSequence,
                        isFinal: true
                    )
                    currentSuggestion = frozenSuggestion
                }
            }

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
            if result.currentSuggestion == nil {
                startPostAcceptanceSpeculationIfEligible(
                    context: liveContext,
                    insertedText: result.acceptedText
                )
            }
            schedulePostAcceptanceRefresh(for: action, baseline: liveContext)
            return .accepted
        } catch {
            if acceptingStreamedPartial { streamedSuggestionCoordinator.resumeAfterFailedAcceptance() }
            closePostAcceptanceCommandWindow(reason: .insertionFailed)
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
        let traceContext = currentSuggestion?.traceContext
        if let traceContext {
            recordTrace(traceContext, event: .acceptanceAttempted, outcome: .started)
        }
        guard let liveContext = await revalidatedAcceptanceContext(for: action) else {
            if let traceContext {
                recordTrace(
                    traceContext,
                    event: .acceptanceBlocked,
                    reason: .acceptanceBlocked,
                    outcome: .blocked
                )
                finishTrace(traceContext, reason: .acceptanceBlocked, outcome: .discarded)
            }
            return .passedThrough
        }
        let acceptingStreamedPartial = streamedSuggestionCoordinator.freezeForEarlyAcceptance(currentSuggestion)

        do {
            let insertionStartedAt = ContinuousClock.now
            guard let result = try await acceptanceController.acceptAll(
                currentSuggestion: currentSuggestion,
                currentContext: liveContext,
                using: inserter
            ) else {
                if acceptingStreamedPartial { streamedSuggestionCoordinator.resumeAfterFailedAcceptance() }
                GeometryDebug.log("acceptance passed-through action=\(action.debugName) reason=no-token context=\(debugContext(liveContext)) current=\(debugSuggestionState())")
                return .passedThrough
            }
            let insertionMs = elapsedMs(since: insertionStartedAt)
            if let traceContext {
                recordTrace(traceContext, event: .acceptanceAllowed, outcome: .allowed)
                recordTrace(
                    traceContext,
                    event: .acceptanceInserted,
                    outcome: .inserted,
                    durationMs: insertionMs
                )
                recordTrace(traceContext, event: .sessionExhausted, reason: .exhausted, outcome: .exhausted)
                finishTrace(traceContext, reason: .completed, outcome: .finished)
            }
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
            if acceptingStreamedPartial {
                retireStreamAfterEarlyAcceptance(traceContext: traceContext)
            }
            presenter.hide()
            startPostAcceptanceSpeculationIfEligible(
                context: liveContext,
                insertedText: result.acceptedText
            )
            schedulePostAcceptanceRefresh(for: action, baseline: liveContext)
            return .accepted
        } catch {
            if acceptingStreamedPartial { streamedSuggestionCoordinator.resumeAfterFailedAcceptance() }
            closePostAcceptanceCommandWindow(reason: .insertionFailed)
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

    private func retireStreamAfterEarlyAcceptance(traceContext: CompletionTraceContext?) {
        streamedSuggestionCoordinator.retireAfterEarlyAcceptance()
        predictionController.cancelAll()
        guard let traceContext else { return }
        recordTrace(
            traceContext,
            event: .streamEarlyAccepted,
            reason: .completed,
            outcome: .inserted,
            earlyAcceptance: true
        )
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

    private func startPostAcceptanceSpeculationIfEligible(
        context: TextContext,
        insertedText: String
    ) {
        let route = routingPolicy()?.activeKind ?? .remote
        let decision = postAcceptanceSpeculationPolicy.decision(
            context: context,
            insertedText: insertedText,
            route: route,
            inputMethodState: inputMethodStateProvider()
        )
        guard case .start(let speculative) = decision else {
            if case .ineligible(let reason) = decision {
                SuggestionPipelineLog.log("post-acceptance-speculation-skipped", fields: [
                    "reason=\(reason.rawValue)",
                    "route=\(route.rawValue)"
                ])
            }
            return
        }

        let generation = postAcceptanceCommandBuffer.arm(
            duration: postAcceptanceSpeculationPolicy.configuration.commandWindow
        )
        postAcceptanceCommandTimeoutTask?.cancel()
        postAcceptanceCommandTimeoutTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let nanoseconds = UInt64(
                postAcceptanceSpeculationPolicy.configuration.commandWindow * 1_000_000_000
            )
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled,
                  postAcceptanceCommandBuffer.expire(generation: generation) else {
                return
            }
            releasePendingPostAcceptanceCommand(outcome: .passedThrough, event: "expired")
        }
        SuggestionPipelineLog.log("post-acceptance-speculation-started", fields: [
            "route=\(route.rawValue)",
            "generation=\(generation)",
            "commandWindowMs=\(Int(postAcceptanceSpeculationPolicy.configuration.commandWindow * 1_000))"
        ])
        requestCompletion(
            for: speculative.context,
            invocation: .automatic,
            speculation: speculative
        )
    }

    private func enqueuePostAcceptanceCommand(
        using inserter: TextInserter
    ) async -> SuggestionAcceptanceCommandOutcome {
        switch postAcceptanceCommandBuffer.enqueue() {
        case .inactive:
            return .passedThrough
        case .alreadyQueued(let generation):
            SuggestionPipelineLog.log("post-acceptance-command", fields: [
                "action=additional-command-suppressed",
                "generation=\(generation)"
            ])
            return .accepted
        case .queued(let generation):
            SuggestionPipelineLog.log("post-acceptance-command", fields: [
                "action=queued",
                "generation=\(generation)"
            ])
            return await withCheckedContinuation { continuation in
                pendingPostAcceptanceCommand = PendingPostAcceptanceCommand(
                    generation: generation,
                    inserter: inserter,
                    continuation: continuation
                )
            }
        }
    }

    private func consumePendingPostAcceptanceCommandIfNeeded() {
        guard let pending = pendingPostAcceptanceCommand,
              postAcceptanceCommandBuffer.consume() == pending.generation else {
            if postAcceptanceCommandBuffer.shouldIntercept(), !postAcceptanceCommandBuffer.hasQueuedCommand {
                postAcceptanceCommandBuffer.close(.consumed)
                postAcceptanceCommandTimeoutTask?.cancel()
                postAcceptanceCommandTimeoutTask = nil
            }
            return
        }
        pendingPostAcceptanceCommand = nil
        postAcceptanceCommandTimeoutTask?.cancel()
        postAcceptanceCommandTimeoutTask = nil
        SuggestionPipelineLog.log("post-acceptance-command", fields: [
            "action=consuming",
            "generation=\(pending.generation)"
        ])
        Task { @MainActor [weak self] in
            guard let self else {
                pending.continuation.resume(returning: .passedThrough)
                return
            }
            let outcome = await acceptNextWord(using: pending.inserter)
            pending.continuation.resume(returning: outcome == .failed ? .passedThrough : outcome)
        }
    }

    private func closePostAcceptanceCommandWindow(
        reason: PostAcceptanceCommandBuffer.CloseReason
    ) {
        switch reason {
        case .expired, .consumed:
            break
        case .incompatibleInput, .focusChanged, .insertionFailed, .teardown:
            predictionController.cancelAll()
        }
        let hadPendingCommand = pendingPostAcceptanceCommand != nil
        postAcceptanceCommandBuffer.close(reason)
        postAcceptanceCommandTimeoutTask?.cancel()
        postAcceptanceCommandTimeoutTask = nil
        if hadPendingCommand {
            releasePendingPostAcceptanceCommand(outcome: .passedThrough, event: reason.rawValue)
        }
        SuggestionPipelineLog.log("post-acceptance-command-window", fields: [
            "action=closed",
            "reason=\(reason.rawValue)",
            "hadPending=\(hadPendingCommand)"
        ])
    }

    private func releasePendingPostAcceptanceCommand(
        outcome: SuggestionAcceptanceCommandOutcome,
        event: String
    ) {
        guard let pending = pendingPostAcceptanceCommand else { return }
        pendingPostAcceptanceCommand = nil
        SuggestionPipelineLog.log("post-acceptance-command", fields: [
            "action=released",
            "reason=\(event)",
            "generation=\(pending.generation)"
        ])
        pending.continuation.resume(returning: outcome)
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
            return action.shouldSchedulePrediction || action.event.isDeletionMutation
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
        refreshOnTimeout: Bool,
        traceContext: CompletionTraceContext? = nil
    ) async {
        guard isAutocompleteEnabled, !isInteractionPipelineSuspended else {
            if isInteractionPipelineSuspended {
                GeometryDebug.log("host-publish skipped reason=pipeline-suspended source=\(source.debugName)")
            }
            return
        }

        if let traceContext {
            recordTrace(traceContext, event: .hostPublishStarted, outcome: .started)
        }
        let result = await hostPublishAwaiter.awaitPublication(
            after: baseline,
            provider: focusProvider,
            reason: source.debugName
        )

        switch result.outcome {
        case .ready:
            if let traceContext {
                recordTrace(
                    traceContext,
                    event: .hostPublishReady,
                    outcome: .ready,
                    durationMs: result.elapsedMs,
                    hostPublishOutcome: .published,
                    hostPublishMs: result.elapsedMs,
                    hostPublishPollCount: result.pollCount
                )
            }
            GeometryDebug.log("host-publish ready source=\(source.debugName) elapsedMs=\(result.elapsedMs) polls=\(result.pollCount)")
            requestRefresh(
                source: source,
                traceContext: traceContext,
                schedulingEvidence: SuggestionRefreshSchedulingEvidence(
                    hostPublishOutcome: .published,
                    hostPublishElapsedMs: result.elapsedMs,
                    hostPublishPollCount: result.pollCount
                )
            )
        case .timeout:
            if let traceContext {
                recordTrace(
                    traceContext,
                    event: .hostPublishTimeout,
                    reason: .timeout,
                    outcome: .discarded,
                    durationMs: result.elapsedMs,
                    hostPublishOutcome: .timeout,
                    hostPublishMs: result.elapsedMs,
                    hostPublishPollCount: result.pollCount
                )
            }
            GeometryDebug.log("host-publish timeout source=\(source.debugName) elapsedMs=\(result.elapsedMs) refresh=\(refreshOnTimeout)")
            if refreshOnTimeout {
                requestRefresh(
                    source: source,
                    traceContext: traceContext,
                    schedulingEvidence: SuggestionRefreshSchedulingEvidence(
                        hostPublishOutcome: .timeout,
                        hostPublishElapsedMs: result.elapsedMs,
                        hostPublishPollCount: result.pollCount
                    )
                )
            } else if let traceContext {
                finishTrace(traceContext, reason: .timeout, outcome: .discarded)
            }
        case .cancelled:
            if let traceContext {
                recordTrace(
                    traceContext,
                    event: .hostPublishCancelled,
                    reason: .taskCancelled,
                    outcome: .cancelled,
                    durationMs: result.elapsedMs,
                    hostPublishOutcome: .cancelled,
                    hostPublishMs: result.elapsedMs,
                    hostPublishPollCount: result.pollCount
                )
                finishTrace(traceContext, reason: .taskCancelled, outcome: .cancelled)
            }
            GeometryDebug.log("host-publish cancelled source=\(source.debugName) elapsedMs=\(result.elapsedMs)")
        }
    }

    private func requestRefresh(
        source: SuggestionRefreshSource,
        traceContext suppliedTraceContext: CompletionTraceContext? = nil,
        schedulingEvidence: SuggestionRefreshSchedulingEvidence = .notAwaited
    ) {
        guard !isInteractionPipelineSuspended else {
            RefreshDiagnostics.log("refresh-request skipped reason=pipeline-suspended source=\(source.debugName)")
            if let suppliedTraceContext {
                finishTrace(suppliedTraceContext, reason: .pipelineSuspended, outcome: .discarded)
            }
            return
        }
        let traceContext = suppliedTraceContext ?? startCompletionTrace()

        let queuedDebugName = refreshQueuedSource?.debugName ?? "nil"
        RefreshDiagnostics.log("refresh-request source=\(source.debugName) inFlight=\(refreshTask != nil) queued=\(queuedDebugName)")
        SuggestionPipelineLog.log("refresh-request", fields: [
            "source=\(source.debugName)",
            "inFlight=\(refreshTask != nil)",
            "queued=\(queuedDebugName)"
        ])

        // Single-flight: if a refresh is already running, remember we need another pass.
        if refreshTask != nil {
            if let queued = refreshQueuedSource,
               queued.coalescingPriority > source.coalescingPriority {
                RefreshDiagnostics.log("refresh-queue dropped source=\(source.debugName) reason=lower-priority queued=\(queued.debugName)")
                finishTrace(traceContext, reason: .superseded, outcome: .cancelled)
                return
            }
            // Coalesce: keep the most recent trigger as the queued source for diagnostics.
            if let queuedTraceContext = refreshQueuedTraceContext,
               queuedTraceContext.traceID != traceContext.traceID {
                finishTrace(queuedTraceContext, reason: .superseded, outcome: .cancelled)
            }
            refreshQueuedSource = source
            refreshQueuedTraceContext = traceContext
            refreshQueuedSchedulingEvidence = schedulingEvidence
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

            await self.performRefreshSingleFlight(
                initialSource: source,
                initialTraceContext: traceContext,
                initialSchedulingEvidence: schedulingEvidence
            )
        }
    }

    private func performRefreshSingleFlight(
        initialSource: SuggestionRefreshSource,
        initialTraceContext: CompletionTraceContext?,
        initialSchedulingEvidence: SuggestionRefreshSchedulingEvidence
    ) async {
        var sourceToRun = initialSource
        var traceContextToRun = initialTraceContext
        var schedulingEvidenceToRun = initialSchedulingEvidence

        while true {
            guard !isInteractionPipelineSuspended else {
                refreshTask = nil
                refreshQueuedSource = nil
                refreshQueuedTraceContext = nil
                refreshQueuedSchedulingEvidence = nil
                RefreshDiagnostics.log("refresh-single-flight stopped reason=pipeline-suspended source=\(sourceToRun.debugName)")
                return
            }

            await refresh(
                source: sourceToRun,
                traceContext: traceContextToRun,
                schedulingEvidence: schedulingEvidenceToRun
            )

            if let queued = refreshQueuedSource {
                refreshQueuedSource = nil
                sourceToRun = queued
                traceContextToRun = refreshQueuedTraceContext
                refreshQueuedTraceContext = nil
                schedulingEvidenceToRun = refreshQueuedSchedulingEvidence ?? .notAwaited
                refreshQueuedSchedulingEvidence = nil
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

    private func refresh(
        source: SuggestionRefreshSource,
        traceContext suppliedTraceContext: CompletionTraceContext? = nil,
        schedulingEvidence: SuggestionRefreshSchedulingEvidence = .notAwaited
    ) async {
        guard isAutocompleteEnabled, !isInteractionPipelineSuspended else {
            if isInteractionPipelineSuspended {
                RefreshDiagnostics.log("refresh-skipped reason=pipeline-suspended source=\(source.debugName)")
            }
            return
        }

        let traceContext = suppliedTraceContext ?? startCompletionTrace()
        var traceHandedOff = false
        let refreshStartedAt = ContinuousClock.now
        defer {
            let elapsed = elapsedMs(since: refreshStartedAt)
            RefreshDiagnostics.log("refresh-end source=\(source.debugName) elapsedMs=\(elapsed) status=\(statusMessage)")
            SuggestionPipelineLog.log("refresh-end", fields: [
                "source=\(source.debugName)",
                "elapsedMs=\(elapsed)",
                "status=\(SuggestionPipelineLog.privacySafeTextSummary(statusMessage))"
            ])
            if !traceHandedOff {
                finishTrace(traceContext, reason: .unknown, outcome: .discarded)
            }
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
            recordTrace(
                traceContext,
                event: .contextCaptured,
                outcome: .ready,
                prefixUTF16Length: (context.textBeforeCursor as NSString).length,
                suffixUTF16Length: context.textAfterCursor.map { ($0 as NSString).length } ?? 0
            )
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

            var refreshDecision = makeRefreshDecision(for: context)
            if case .clearDismissalAndContinue = refreshDecision {
                dismissedContext = nil
                refreshDecision = makeRefreshDecision(for: context)
            }

            switch refreshDecision {
            case .repairCompletedAcceptAll:
                break
            default:
                acceptanceSessionController.clearCompletedAcceptAllLeakIfInvalid(context: context)
            }

            switch refreshDecision {
            case .clearDismissalAndContinue:
                assertionFailure("clearDismissalAndContinue should be normalized before branch handling")
                return

            case .keepDismissed:
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

            case .evaluateEmptyContextEligibility:
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

            case .repairLeakedShortcut:
                guard await repairLeakedShortcutIfNeeded(context) else {
                    break
                }
                GeometryDebug.log("refresh-branch action=shortcut-repair")
                SuggestionPipelineLog.log("refresh-branch", fields: [
                    "action=shortcut-repair",
                    "context=\(SuggestionPipelineLog.contextDescription(context))",
                    "current=\(SuggestionPipelineLog.suggestionDescription(currentSuggestion))"
                ])
                return

            case .repairCompletedAcceptAll:
                guard repairCompletedAcceptAllLeakIfNeeded(context) else {
                    break
                }
                GeometryDebug.log("refresh-branch action=completed-accept-all-repair")
                SuggestionPipelineLog.log("refresh-branch", fields: [
                    "action=completed-accept-all-repair",
                    "context=\(SuggestionPipelineLog.contextDescription(context))"
                ])
                return

            case .handleAcceptedSession:
                guard handleAcceptedSuggestionSession(context) else {
                    break
                }
                GeometryDebug.log("refresh-branch action=accepted-session")
                SuggestionPipelineLog.log("refresh-branch", fields: [
                    "action=accepted-session",
                    "context=\(SuggestionPipelineLog.contextDescription(context))",
                    "current=\(SuggestionPipelineLog.suggestionDescription(currentSuggestion))"
                ])
                return

            case .keepSuggestion(let reason, let presentationContext):
                guard let suggestion = currentSuggestion else {
                    break
                }
                currentContext = presentationContext
                if reason == .webWhitespaceNormalization {
                    predictionController.cancelAll()
                }
                GeometryDebug.log("suggestion-keep reason=\(reason.rawValue) context=\(debugContext(context)) current=\(debugSuggestionState(suggestion))")
                SuggestionPipelineLog.log("suggestion-keep", fields: [
                    "reason=\(reason.rawValue)",
                    "context=\(SuggestionPipelineLog.contextDescription(context))",
                    "current=\(SuggestionPipelineLog.suggestionDescription(suggestion))"
                ])
                presenter.update(suggestion, for: presentationContext, mode: displayMode(for: presentationContext))
                return

            case .ineligible(let decision):
                applyIneligibleDecision(decision, context: context)
                return

            case .requestCompletion:
                break

            case .evaluateEligibility:
                break
            }

            if publishReusableSuggestionIfAvailable(
                context: context,
                source: source,
                traceContext: traceContext,
                latencySeed: latencySeed
            ) {
                traceHandedOff = true
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
            recordTrace(
                traceContext,
                event: .eligibilityDecided,
                outcome: eligibilityDecision.isEligible ? .allowed : .blocked
            )
            let postEligibilityDecision = makeRefreshDecision(for: context, eligibilityDecision: eligibilityDecision)
            switch postEligibilityDecision {
            case .ineligible(let decision):
                applyIneligibleDecision(decision, context: context)
                return
            case .requestCompletion:
                break
            case .clearDismissalAndContinue,
                 .keepDismissed,
                 .evaluateEmptyContextEligibility,
                 .repairLeakedShortcut,
                 .repairCompletedAcceptAll,
                 .handleAcceptedSession,
                 .keepSuggestion,
                 .evaluateEligibility:
                break
            }

            currentContext = context
            predictionController.cancelAll()
            acceptanceSessionController.clearAll()

            if let emojiSuggestion = emojiService.suggestion(for: context.textBeforeCursor, contextID: context.id) {
                traceHandedOff = true
                GeometryDebug.log("completion-path source=emoji context=\(debugContext(context))")
                publish(
                    emojiSuggestion,
                    context: context,
                    latencyReport: completionLatencyReport(from: latencySeed),
                    latencyStartedAt: latencySeed.startedAt,
                    traceContext: traceContext
                )
                return
            }

            // Debounce: hide the current suggestion and wait for the user to
            // stop typing before requesting a new completion.
            hideSuggestion(reason: "eligible-new-context", context: context)
            inputController.clearSuggestionTrigger()
            let route = routingPolicy()?.activeKind ?? .remote
            let schedulingDecision = schedulingPolicy.decision(.init(
                route: route,
                invocation: .automatic,
                mutation: source.schedulingMutation,
                recentBackendLatencyMs: backendLatencyHistory.robustLatencyMs(for: route),
                hostPublishElapsedMs: schedulingEvidence.hostPublishElapsedMs,
                hostPublishOutcome: schedulingEvidence.hostPublishOutcome,
                recentTypingIntervalMs: recentTypingIntervalMs,
                isComposingText: inputMethodState.isComposingText
            ))
            recordTrace(
                traceContext,
                event: .schedulingDecided,
                reason: .automatic,
                outcome: schedulingDecision.action == .suppress ? .blocked : .ready,
                requestedBackend: route,
                hostPublishOutcome: schedulingEvidence.hostPublishOutcome,
                hostPublishMs: schedulingEvidence.hostPublishElapsedMs,
                hostPublishPollCount: schedulingEvidence.hostPublishPollCount,
                targetDebounceMs: schedulingDecision.targetDebounceMs,
                remainingDebounceMs: schedulingDecision.remainingDebounceMs,
                schedulingReason: schedulingDecision.reason,
                recentBackendLatencyMs: schedulingDecision.recentBackendLatencyMs,
                providerCallStarted: false
            )
            SuggestionPipelineLog.log("scheduling-decision", fields: [
                "policyVersion=\(SuggestionSchedulingPolicy.currentPolicyVersion)",
                "source=\(source.debugName)",
                "route=\(route.rawValue)",
                "hostPublishOutcome=\(schedulingEvidence.hostPublishOutcome.rawValue)",
                "hostPublishMs=\(schedulingEvidence.hostPublishElapsedMs)",
                "hostPublishPolls=\(schedulingEvidence.hostPublishPollCount)",
                "targetDebounceMs=\(schedulingDecision.targetDebounceMs)",
                "remainingDebounceMs=\(schedulingDecision.remainingDebounceMs)",
                "recentBackendLatencyMs=\(schedulingDecision.recentBackendLatencyMs ?? -1)",
                "reason=\(schedulingDecision.reason.rawValue)"
            ])
            guard schedulingDecision.action != .suppress else {
                finishTrace(traceContext, reason: .unknown, outcome: .discarded)
                return
            }

            if schedulingDecision.shouldGenerateImmediately {
                var immediateLatencySeed = latencySeed
                immediateLatencySeed.debounceMs = 0
                traceHandedOff = true
                requestCompletion(
                    for: context,
                    invocation: .automatic,
                    latencySeed: immediateLatencySeed,
                    traceContext: traceContext
                )
                return
            }

            let debounceMs = schedulingDecision.remainingDebounceMs
            traceHandedOff = true
            let debounceWorkID = predictionController.replaceScheduledWork(
                decision: schedulingDecision
            ) { [weak self, latencySeed, traceContext] workID, outcome in
                guard let engine = self else { return }
                await MainActor.run {
                    switch outcome {
                    case .cancelled(let elapsedMs):
                        engine.recordTrace(
                            traceContext,
                            event: .debounceCancelled,
                            reason: .taskCancelled,
                            outcome: .cancelled,
                            workID: workID,
                            durationMs: elapsedMs,
                            providerCallStarted: false
                        )
                        engine.finishTrace(traceContext, reason: .taskCancelled, outcome: .cancelled)
                        return
                    case .ready(let elapsedMs):
                        guard engine.predictionController.isCurrent(workID) else {
                            engine.recordTrace(
                                traceContext,
                                event: .debounceCancelled,
                                reason: .superseded,
                                outcome: .cancelled,
                                workID: workID,
                                durationMs: elapsedMs,
                                providerCallStarted: false
                            )
                            engine.finishTrace(traceContext, reason: .superseded, outcome: .cancelled)
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
                        engine.recordTrace(
                            traceContext,
                            event: .debounceElapsed,
                            outcome: .ready,
                            workID: workID,
                            durationMs: elapsedMs
                        )
                        SuggestionPipelineLog.log("completion-debounce-fired", fields: [
                            "workID=\(workID)",
                            "source=\(source.debugName)",
                            "context=\(SuggestionPipelineLog.contextDescription(context))"
                        ])
                        var firedLatencySeed = latencySeed
                        firedLatencySeed.debounceMs = elapsedMs
                        engine.requestCompletion(
                            for: context,
                            invocation: .automatic,
                            latencySeed: firedLatencySeed,
                            traceContext: traceContext
                        )
                    }
                }
            }
            recordTrace(
                traceContext,
                event: .debounceStarted,
                outcome: .started,
                workID: debounceWorkID,
                durationMs: debounceMs
            )
            GeometryDebug.log("completion-debounce scheduled workID=\(debounceWorkID) generation=\(debounceWorkID) source=\(source.debugName) intervalMs=\(debounceMs) context=\(debugContext(context))")
            SuggestionPipelineLog.log("completion-debounce-scheduled", fields: [
                "workID=\(debounceWorkID)",
                "source=\(source.debugName)",
                "intervalMs=\(debounceMs)",
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
            reuseStore.reset()
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

    private func makeRefreshDecision(
        for context: TextContext,
        eligibilityDecision: SuggestionEligibilityDecision? = nil
    ) -> SuggestionRefreshDecision {
        SuggestionRefreshDecisionEngine.decide(
            SuggestionRefreshDecisionInput(
                context: context,
                previousContext: currentContext,
                currentSuggestion: currentSuggestion,
                dismissedContext: dismissedContext,
                acceptedPrefixConsistent: isCurrentSuggestionAcceptedPrefixConsistent(with: context),
                leakedShortcutRepairNeeded: acceptanceSessionController.canRepairLeakedShortcut(
                    context: context,
                    previousContext: currentContext,
                    currentSuggestion: currentSuggestion,
                    repairInserter: shortcutLeakRepairInserter
                ),
                completedAcceptAllRepairNeeded: acceptanceSessionController.canRepairCompletedAcceptAllLeak(context: context),
                acceptedSessionCanHandle: acceptanceSessionController.shouldHandleAcceptedSuggestionSession(context: context),
                eligibilityDecision: eligibilityDecision
            )
        )
    }

    private func isCurrentSuggestionAcceptedPrefixConsistent(with context: TextContext) -> Bool {
        guard let suggestion = currentSuggestion,
              !suggestion.isExhausted,
              let previousContext = currentContext else {
            return false
        }

        return isTextConsistentWithAcceptedSuggestion(
            context: context,
            previousContext: previousContext,
            suggestion: suggestion
        )
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
        reuseStore.reset()
        closePostAcceptanceCommandWindow(reason: .focusChanged)
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

        return eligibilityCoordinator.allowsVisualContextPreparation(
            for: context,
            userRuleset: privacyStore.load().domainWebAppRules.ruleset
        )
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
        let result = eligibilityCoordinator.evaluate(
            context: context,
            previousContext: previousObservedContext,
            compatibilityDecision: compatibilityDecision,
            userRuleset: privacyStore.load().domainWebAppRules.ruleset,
            invocation: invocation,
            inputMethodState: inputMethodState,
            lastSuggestionTriggerKeyAt: inputController.lastSuggestionTriggerKeyAt,
            visualContextIsReady: visualContextEligibilitySatisfied(for: context)
        )
        if let skipReason = result.domainRuleSkipReason {
            diagnostics.recordDomainRuleDecision(skipReason, domainResolution: domainResolution(for: context))
        }
        return result.decision
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
        max(0, startedAt.duration(to: .now).milliseconds)
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
        (productivityMetrics as? CompletionMetricsRecording)?.recordGeneratedSuggestion()
    }

    private func recordShownSuggestion() {
        (productivityMetrics as? CompletionMetricsRecording)?.recordShownSuggestion()
    }

    private func recordSuppressedSuggestion(reason: String) {
        (productivityMetrics as? CompletionMetricsRecording)?.recordSuppressedSuggestion(reason: reason)
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
        latencySeed: CompletionLatencySeed? = nil,
        traceContext suppliedTraceContext: CompletionTraceContext? = nil,
        speculation: SpeculativePostAcceptanceContext? = nil
    ) {
        let traceContext = suppliedTraceContext ?? startCompletionTrace()
        if let speculation {
            recordTrace(
                traceContext,
                event: .speculationStarted,
                outcome: .started,
                requestedBackend: speculation.route,
                providerCallStarted: false
            )
        }
        if suppliedTraceContext == nil || invocation == .manual {
            let schedulingBackend = routingPolicy()?.activeKind ?? .remote
            let schedulingDecision = schedulingPolicy.decision(.init(
                route: schedulingBackend,
                invocation: invocation == .manual ? .manual : .automatic,
                mutation: .focusOrOther
            ))
            recordTrace(
                traceContext,
                event: .schedulingDecided,
                reason: invocation == .manual ? .manual : .automatic,
                outcome: .ready,
                requestedBackend: schedulingBackend,
                hostPublishOutcome: .notAwaited,
                hostPublishMs: 0,
                hostPublishPollCount: 0,
                targetDebounceMs: schedulingDecision.targetDebounceMs,
                remainingDebounceMs: schedulingDecision.remainingDebounceMs,
                schedulingReason: schedulingDecision.reason,
                recentBackendLatencyMs: schedulingDecision.recentBackendLatencyMs,
                providerCallStarted: false
            )
        }
        let preflightDecision = completionRequestCoordinator.preflight(
            isPipelineSuspended: isInteractionPipelineSuspended,
            isAutomatic: invocation == .automatic,
            backendHealthMonitor: &backendHealthMonitor
        )
        if case .pipelineSuspended = preflightDecision {
            GeometryDebug.log("completion-suppressed reason=pipeline-suspended context=\(debugContext(context))")
            statusMessage = "AutoComp paused"
            recordSuppressedSuggestion(reason: "pipeline-suspended")
            hideSuggestion(reason: "pipeline-suspended", context: context)
            finishTrace(traceContext, reason: .pipelineSuspended, outcome: .discarded)
            return
        }

        switch preflightDecision {
        case .proceed(let summary), .backendSuppressed(let summary):
            backendStatusSummary = summary
        case .pipelineSuspended:
            break
        }
        SuggestionPipelineLog.log("completion-request", fields: [
            "invocation=\(invocation.debugName)",
            "routing=\(SuggestionPipelineLog.routingDescription(routingPolicy()))",
            "context=\(SuggestionPipelineLog.contextDescription(context))"
        ])
        if case .backendSuppressed(let suppression) = preflightDecision {
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
            finishTrace(traceContext, reason: .backendPaused, outcome: .discarded)
            return
        }

        diagnostics.recordBackendRequest(policy: routingPolicy())
        let requestedSignature = contextGenerationTracker.signature(for: context)
        let providerGeneration = providerLifecycleGeneration
        let requestedBackend = routingPolicy()?.activeKind ?? .remote
        let latencyStartedAt = latencySeed?.startedAt ?? ContinuousClock.now
        let initialLatencyReport = completionLatencyReport(from: latencySeed)
        predictionController.replaceGenerationWork { [weak self] workID in
            guard let engine = self else { return }
            await MainActor.run {
                engine.recordTrace(
                    traceContext,
                    event: .requestBuilt,
                    outcome: .ready,
                    workID: workID,
                    prefixUTF16Length: (context.textBeforeCursor as NSString).length,
                    suffixUTF16Length: context.textAfterCursor.map { ($0 as NSString).length } ?? 0
                )
                engine.recordTrace(
                    traceContext,
                    event: .providerStarted,
                    outcome: .started,
                    workID: workID,
                    providerAttempt: 0,
                    requestedBackend: requestedBackend,
                    providerCallStarted: true
                )
            }
            GeometryDebug.log("completion-request workID=\(workID) generation=\(workID) app=\(context.app.displayName) bundle=\(context.app.bundleID) context=\(context.geometryDebugDescription)")
            SuggestionPipelineLog.log("completion-start", fields: [
                "workID=\(workID)",
                "invocation=\(invocation.debugName)",
                "context=\(SuggestionPipelineLog.contextDescription(context))"
            ])
            guard !Task.isCancelled else {
                await MainActor.run {
                    engine.recordTrace(
                        traceContext,
                        event: .providerCancelled,
                        reason: .taskCancelled,
                        outcome: .cancelled,
                        workID: workID,
                        providerAttempt: 0,
                        requestedBackend: requestedBackend,
                        providerCallStarted: false
                    )
                    engine.finishTrace(traceContext, reason: .taskCancelled, outcome: .cancelled)
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
            var pipelineContext = SuggestionPipeline.RequestContext(textContext: context)
            let privacySettings = engine.privacyStore.load()
            let personalizationSamples = await MainActor.run {
                engine.personalizationPromptSamples(
                    for: context,
                    privacySettings: privacySettings
                )
            }
            let isLowTrustRequest = pipelineContext.isLowTrustRequest
            let visualContext: VisualContextSnapshot?
            if isLowTrustRequest || engine.visualContextProvider == nil {
                visualContext = nil
            } else {
                let visualContextStartedAt = ContinuousClock.now
                visualContext = await engine.currentVisualContext(for: context)
                latencyReport.visualContextMs = visualContextStartedAt.duration(to: .now).milliseconds
            }
            guard !Task.isCancelled else {
                await MainActor.run {
                    engine.recordTrace(
                        traceContext,
                        event: .providerCancelled,
                        reason: .taskCancelled,
                        outcome: .cancelled,
                        workID: workID,
                        providerAttempt: 0,
                        requestedBackend: requestedBackend,
                        providerCallStarted: false
                    )
                    engine.finishTrace(traceContext, reason: .taskCancelled, outcome: .cancelled)
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
            if visualContext != nil {
                let shouldReadLiveContextAfterVisual = await MainActor.run {
                    engine.predictionController.isCurrent(workID)
                }
                let liveContextAfterVisual: TextContext?
                if shouldReadLiveContextAfterVisual {
                    liveContextAfterVisual = try? await engine.focusProvider.currentContext()
                } else {
                    liveContextAfterVisual = nil
                }

                let visualContextStillMatches = await MainActor.run {
                    guard let liveContextAfterVisual else {
                        return false
                    }
                    engine.recordTrustedContext(liveContextAfterVisual)
                    return engine.contextGenerationTracker.matches(liveContextAfterVisual, signature: requestedSignature)
                        && engine.visualContext(visualContext, matches: liveContextAfterVisual)
                }
                let visualRevalidationDecision = await MainActor.run {
                    engine.postProviderCoordinator.decideVisualContextRevalidation(
                        workIsCurrent: engine.predictionController.isCurrent(workID),
                        liveContext: liveContextAfterVisual,
                        visualContextMatchesLiveContext: visualContextStillMatches
                    )
                }

                switch visualRevalidationDecision {
                case .continueWithLiveContext:
                    break
                case .discard(.backendSwitchBeforeProvider):
                    await MainActor.run {
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
                            discardReason: PostProviderCompletionCoordinator.DiscardReason.backendSwitchBeforeProvider.rawValue
                        )
                        engine.finishTrace(traceContext, reason: .superseded, outcome: .cancelled)
                    }
                    return
                case .discard(.missingLiveContextAfterVisual):
                    await MainActor.run {
                        guard engine.predictionController.isCurrent(workID) else {
                            engine.finishTrace(traceContext, reason: .superseded, outcome: .cancelled)
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
                        engine.finishTrace(traceContext, reason: .staleContext, outcome: .discarded)
                        engine.hideSuggestion(reason: "missing-live-context-after-visual", context: context)
                    }
                    return
                case .discard(.staleVisualContext):
                    await MainActor.run {
                        guard engine.predictionController.isCurrent(workID) else {
                            engine.finishTrace(traceContext, reason: .superseded, outcome: .cancelled)
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
                        engine.finishTrace(traceContext, reason: .staleContext, outcome: .discarded)
                        engine.hideSuggestion(reason: "stale-visual-context", context: context)
                    }
                    return
                case .discard:
                    await MainActor.run {
                        engine.finishTrace(traceContext, reason: .unknown, outcome: .discarded)
                    }
                    return
                }
            } else {
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
                            discardReason: PostProviderCompletionCoordinator.DiscardReason.backendSwitchBeforeProvider.rawValue
                        )
                        engine.finishTrace(traceContext, reason: .superseded, outcome: .cancelled)
                    }
                    return isCurrent
                }
                guard workStillCurrentAfterVisual else {
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
                latencyReport.clipboardFilterMs = clipboardFilterStartedAt.duration(to: .now).milliseconds
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

            let (isCurrentAfterVisual, provider, requestsMultipleSuggestions, streamingConfiguration) = await MainActor.run {
                (
                    engine.predictionController.isCurrent(workID),
                    engine.generationProvider,
                    engine.shouldRequestMultipleSuggestions(for: context, invocation: invocation),
                    engine.streamingConfiguration
                )
            }
            pipelineContext.prepareProviderInvocation(
                privacySettings: privacySettings,
                personalizationSamples: personalizationSamples,
                visualContext: visualContext,
                clipboardContext: clipboardContext,
                requestsMultipleSuggestions: requestsMultipleSuggestions
            )
            await MainActor.run {
                SuggestionPipelineLog.log("provider-start", fields: [
                    "workID=\(workID)",
                    "current=\(isCurrentAfterVisual)",
                    "routing=\(SuggestionPipelineLog.routingDescription(engine.routingPolicy()))",
                    "suggestionCount=\(pipelineContext.completionOptions.suggestionCount)",
                    "context=\(SuggestionPipelineLog.contextDescription(context))"
                ])
            }
            let streamingMetadata = StreamingCompletionMetadata(
                traceContext: traceContext,
                workID: workID,
                requestedRoute: requestedBackend
            )
            let streamingEnabled = !requestsMultipleSuggestions
                && streamingConfiguration.enables(
                    (provider as? any StreamingCompletionProvider)?.streamingCompletionCapability
                )
            if streamingEnabled {
                await MainActor.run {
                    engine.streamedSuggestionCoordinator.begin(streamingMetadata)
                }
            }
            let invocationResult = await engine.completionRequestCoordinator.invoke(
                context: &pipelineContext,
                provider: provider,
                isCurrent: isCurrentAfterVisual,
                streamingConfiguration: streamingConfiguration,
                streamingMetadata: streamingMetadata,
                onPartial: { [weak engine] partial in
                    guard let engine else { return }
                    let liveContext = try? await engine.focusProvider.currentContext()
                    await MainActor.run {
                        engine.handleStreamedPartial(
                            partial,
                            liveContext: liveContext,
                            requestedSignature: requestedSignature,
                            providerGeneration: providerGeneration
                        )
                    }
                }
            )
            let pipelineOutcome = invocationResult.outcome
            latencyReport.backendMs = invocationResult.backendLatencyMs
            if case .publish = pipelineOutcome, let backendMs = latencyReport.backendMs {
                await MainActor.run {
                    engine.backendLatencyHistory.record(backendMs, for: requestedBackend)
                }
            }
            await MainActor.run {
                SuggestionPipelineLog.log("provider-finished", fields: [
                    "workID=\(workID)",
                    "outcome=\(Self.pipelineOutcomeDescription(pipelineOutcome))",
                    "backendMs=\(latencyReport.backendMs ?? -1)",
                    "context=\(SuggestionPipelineLog.contextDescription(context))"
                ])
                engine.recordProviderTraceOutcome(
                    pipelineOutcome,
                    traceContext: traceContext,
                    workID: workID,
                    durationMs: latencyReport.backendMs
                )
            }

            let promptCacheStats = await engine.promptCacheStatsIfAvailable()

            switch pipelineOutcome {
            case .publish(let suggestion):
                if await MainActor.run(body: {
                    guard engine.streamedSuggestionCoordinator.didHandleFinal(suggestion.streamingMetadata) else {
                        return false
                    }
                    if engine.predictionController.isCurrent(workID) {
                        engine.recordGeneratedSuggestion()
                        engine.backendStatusSummary = engine.backendHealthMonitor.recordSuccess()
                        engine.diagnostics.recordPromptCache(promptCacheStats)
                    }
                    return true
                }) {
                    return
                }
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
                    if engine.postProviderCoordinator.decideBackendHealth(
                        for: SuggestionPipeline.Outcome<Suggestion>.publish(suggestion)
                    ) == .recordSuccess {
                        engine.backendStatusSummary = engine.backendHealthMonitor.recordSuccess()
                    }
                }

                let liveContext: TextContext?
                if isLowTrustRequest {
                    liveContext = nil
                } else {
                    liveContext = try? await engine.focusProvider.currentContext()
                }
                let liveRevalidationInputs = await MainActor.run {
                    let workIsCurrent = engine.predictionController.isCurrent(workID)
                    let providerLifecycleMatches = engine.providerLifecycleGeneration == providerGeneration
                    guard workIsCurrent, let liveContext else {
                        return (
                            workIsCurrent: workIsCurrent,
                            providerLifecycleMatches: providerLifecycleMatches,
                            liveContextMatchesRequest: false
                        )
                    }

                    let liveContextMatchesRequest = engine.contextGenerationTracker.matches(
                        liveContext,
                        signature: requestedSignature
                    ) && (speculation?.signature.matches(liveContext) ?? true)
                    engine.recordTrustedContext(liveContext)
                    GeometryDebug.log("completion-live-context match=\(liveContextMatchesRequest) requested=\(engine.debugContext(context)) live=\(engine.debugContext(liveContext))")
                    SuggestionPipelineLog.log("completion-revalidation", fields: [
                        "workID=\(workID)",
                        "match=\(liveContextMatchesRequest)",
                        "requested=\(SuggestionPipelineLog.contextDescription(context))",
                        "live=\(SuggestionPipelineLog.contextDescription(liveContext))",
                        "suggestion=\(SuggestionPipelineLog.suggestionDescription(suggestion))"
                    ])
                    return (
                        workIsCurrent: workIsCurrent,
                        providerLifecycleMatches: providerLifecycleMatches,
                        liveContextMatchesRequest: liveContextMatchesRequest
                    )
                }
                let liveRevalidationDecision = engine.postProviderCoordinator.decideLiveRevalidation(
                    requestedContext: context,
                    isLowTrustRequest: isLowTrustRequest,
                    workIsCurrent: liveRevalidationInputs.workIsCurrent,
                    providerLifecycleMatches: liveRevalidationInputs.providerLifecycleMatches,
                    liveContext: liveContext,
                    liveContextMatchesRequest: liveRevalidationInputs.liveContextMatchesRequest
                )
                await MainActor.run {
                    engine.recordTrace(
                        traceContext,
                        event: .liveContextRevalidated,
                        reason: liveRevalidationInputs.liveContextMatchesRequest ? nil : .staleContext,
                        outcome: liveRevalidationInputs.liveContextMatchesRequest || isLowTrustRequest ? .allowed : .blocked,
                        workID: workID
                    )
                    if speculation != nil {
                        engine.recordTrace(
                            traceContext,
                            event: liveRevalidationInputs.liveContextMatchesRequest
                                ? .speculationValidated
                                : .speculationDiverged,
                            reason: liveRevalidationInputs.liveContextMatchesRequest ? nil : .staleContext,
                            outcome: liveRevalidationInputs.liveContextMatchesRequest ? .allowed : .discarded,
                            workID: workID,
                            requestedBackend: requestedBackend,
                            providerCallStarted: true
                        )
                        SuggestionPipelineLog.log("post-acceptance-speculation-finished", fields: [
                            "workID=\(workID)",
                            "route=\(requestedBackend.rawValue)",
                            "result=\(liveRevalidationInputs.liveContextMatchesRequest ? "validated" : "diverged")"
                        ])
                    }
                }

                switch liveRevalidationDecision {
                case .publish(let publishContext, .skippedLowTrust):
                    await MainActor.run {
                        guard engine.predictionController.isCurrent(workID) else {
                            return
                        }
                        GeometryDebug.log("completion-success revalidation=skipped-low-trust context=\(engine.debugContext(publishContext)) suggestion=\(engine.debugSuggestionState(suggestion))")
                        SuggestionPipelineLog.log("completion-revalidation", fields: [
                            "workID=\(workID)",
                            "result=skipped-low-trust",
                            "context=\(SuggestionPipelineLog.contextDescription(publishContext))",
                            "suggestion=\(SuggestionPipelineLog.suggestionDescription(suggestion))"
                        ])
                        let result = engine.publish(
                            suggestion,
                            context: publishContext,
                            latencyReport: completionLatencyReport,
                            latencyStartedAt: latencyStartedAt,
                            traceContext: traceContext
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

                case .publish(let publishContext, .liveContextMatched):
                    await MainActor.run {
                        guard engine.predictionController.isCurrent(workID) else {
                            return
                        }
                        GeometryDebug.log("completion-success context=\(engine.debugContext(publishContext)) suggestion=\(engine.debugSuggestionState(suggestion))")
                        let result = engine.publish(
                            suggestion,
                            context: publishContext,
                            latencyReport: completionLatencyReport,
                            latencyStartedAt: latencyStartedAt,
                            traceContext: traceContext
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

                case .discard(.missingLiveContext, _):
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
                        engine.finishTrace(traceContext, reason: .staleContext, outcome: .discarded)
                        engine.hideSuggestion(reason: "missing-live-context", context: context)
                    }

                case .discard(.staleWork, let shouldRecordStaleDiscard):
                    await MainActor.run {
                        if let liveContext {
                            GeometryDebug.log("completion-discarded reason=stale-work requested=\(engine.debugContext(context)) live=\(engine.debugContext(liveContext))")
                        } else {
                            GeometryDebug.log("completion-discarded reason=stale-work requested=\(engine.debugContext(context))")
                        }
                        SuggestionPipelineLog.log("completion-discarded", fields: [
                            "workID=\(workID)",
                            "reason=stale-work",
                            "requested=\(SuggestionPipelineLog.contextDescription(context))",
                            "live=\(SuggestionPipelineLog.contextDescription(liveContext))",
                            "suggestion=\(SuggestionPipelineLog.suggestionDescription(suggestion))"
                        ])
                        if shouldRecordStaleDiscard {
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
                        engine.finishTrace(traceContext, reason: .staleWork, outcome: .discarded)
                    }

                case .discard(.staleContext, _):
                    await MainActor.run {
                        guard engine.predictionController.isCurrent(workID) else {
                            return
                        }
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
                        engine.finishTrace(traceContext, reason: .staleContext, outcome: .discarded)
                    }

                case .discard:
                    await MainActor.run {
                        engine.finishTrace(traceContext, reason: .unknown, outcome: .discarded)
                    }
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
                    engine.finishTrace(traceContext, reason: .staleWork, outcome: .discarded)
                    engine.hideSuggestion(reason: reason.message ?? reason.kind.rawValue, context: context)
                }

            case .failure(let reason):
                await MainActor.run {
                    guard engine.predictionController.isCurrent(workID) else { return }
                    guard case let .recordFailure(message, suppressedReason, backendIssue) = engine.postProviderCoordinator.decideBackendHealth(
                        for: SuggestionPipeline.Outcome<Suggestion>.failure(reason)
                    ) else {
                        return
                    }
                    let failureError = ProviderInvocationFailureError(message: message)
                    GeometryDebug.log("completion-failed context=\(engine.debugContext(context)) error=\(message)")
                    engine.recordSuppressedSuggestion(reason: suppressedReason)
                    SuggestionPipelineLog.log("completion-failed", fields: [
                        "workID=\(workID)",
                        "kind=\(reason.kind.rawValue)",
                        "issue=\(backendIssue?.logValue ?? "unknown")",
                        "error=\(SuggestionPipelineLog.privacySafeTextSummary(message))",
                        "context=\(SuggestionPipelineLog.contextDescription(context))"
                    ])
                    engine.diagnostics.recordBackendFailure(message: message, kind: engine.routingPolicy()?.activeKind)
                    if let issue = backendIssue {
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
                    engine.finishTrace(traceContext, reason: .providerFailure, outcome: .failed)
                    engine.hideSuggestion(reason: "completion-failed", context: context)
                }

            case .continue:
                break
            }
        }
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
        GoogleDocsContext.matches(bundleID: context.app.bundleID, domain: context.domain, appGate: .webLike)
    }

    func resetInMemorySuggestionState(reason: String) {
        reuseStore.reset()
        SuggestionPipelineLog.log("reuse-reset", fields: ["reason=\(reason)"])
    }

    private func publishReusableSuggestionIfAvailable(
        context: TextContext,
        source: SuggestionRefreshSource,
        traceContext: CompletionTraceContext,
        latencySeed: CompletionLatencySeed
    ) -> Bool {
        let mutation = source.reuseMutation
        guard mutation != .other else { return false }
        let route = routingPolicy()?.activeKind ?? .remote
        let decision = reuseStore.decision(for: context, backend: route, mutation: mutation)

        let match: SuggestionReuseMatch
        let event: CompletionTraceEventName
        let action: String
        switch decision {
        case .promoteAppend(let value):
            match = value
            event = .reusePromoted
            action = "promote-append"
        case .restoreRollback(let value):
            match = value
            event = .reuseRollbackRestored
            action = "restore-rollback"
        case .mustRecompute(let reason):
            recordTrace(
                traceContext,
                event: .reuseMiss,
                reason: .reuseMiss,
                outcome: .discarded,
                requestedBackend: route,
                providerCallStarted: false
            )
            SuggestionPipelineLog.log("reuse-miss", fields: [
                "reason=\(reason.rawValue)",
                "route=\(route.rawValue)"
            ])
            return false
        case .notApplicable:
            return false
        }

        currentContext = context
        predictionController.cancelAll()
        acceptanceSessionController.clearAll()
        inputController.clearSuggestionTrigger()
        let suggestion = Suggestion(
            baseContextID: context.id,
            visibleText: match.remainingText,
            completionRoute: CompletionRoute(requestedKind: route, deliveredKind: route),
            latencyMs: 0
        )
        recordTrace(
            traceContext,
            event: event,
            outcome: .ready,
            requestedBackend: route,
            deliveredBackend: route,
            candidateRank: match.sourceRank,
            providerCallStarted: false,
            reuseSnapshotAgeBucket: reuseAgeBucket(match.snapshotAgeMs),
            remainingCharacterBucket: reuseCharacterBucket(match.remainingText.count)
        )
        SuggestionPipelineLog.log("reuse-hit", fields: [
            "action=\(action)",
            "route=\(route.rawValue)",
            "sourceRank=\(match.sourceRank)",
            "ageBucket=\(reuseAgeBucket(match.snapshotAgeMs))",
            "remainingBucket=\(reuseCharacterBucket(match.remainingText.count))",
            "providerSkipped=true"
        ])
        publish(
            suggestion,
            context: context,
            latencyReport: completionLatencyReport(from: latencySeed),
            latencyStartedAt: latencySeed.startedAt,
            traceContext: traceContext,
            recordForReuse: false,
            providerCallOccurred: false
        )
        return true
    }

    private func recordReusableCandidates(from suggestion: Suggestion, context: TextContext) {
        let route = suggestion.completionRoute?.deliveredKind ?? routingPolicy()?.activeKind ?? .remote
        let candidates = suggestion.alternatives.enumerated().compactMap { rank, alternative -> SuggestionReusableCandidate? in
            let candidate = Suggestion(
                baseContextID: context.id,
                visibleText: alternative.visibleText,
                rawText: alternative.rawText,
                completionRoute: suggestion.completionRoute,
                latencyMs: suggestion.latencyMs
            )
            guard case .publish(let normalized) = SuggestionPublicationPolicy.evaluate(candidate, for: context),
                  !normalized.visibleText.isEmpty else {
                return nil
            }
            return SuggestionReusableCandidate(text: normalized.visibleText, originalRank: rank)
        }
        let evictionsBefore = reuseStore.evictionCount
        reuseStore.record(SuggestionCandidateSnapshot(context: context, backend: route, candidates: candidates))
        SuggestionPipelineLog.log("reuse-snapshot", fields: [
            "route=\(route.rawValue)",
            "candidateCount=\(candidates.count)",
            "snapshotCount=\(reuseStore.snapshotCount)",
            "evictions=\(reuseStore.evictionCount - evictionsBefore)"
        ])
    }

    private func reuseAgeBucket(_ milliseconds: Int) -> Int {
        switch milliseconds {
        case ..<1_000: return 0
        case ..<5_000: return 1
        case ..<15_000: return 2
        default: return 3
        }
    }

    private func reuseCharacterBucket(_ count: Int) -> Int {
        switch count {
        case ...4: return 0
        case ...12: return 1
        case ...32: return 2
        default: return 3
        }
    }

    private func handleStreamedPartial(
        _ partial: CompletionPartial,
        liveContext: TextContext?,
        requestedSignature: StrictGenerationSignature,
        providerGeneration: Int
    ) {
        let traceContext = partial.metadata.traceContext
        recordTrace(
            traceContext,
            event: partial.isFinal ? .streamFinalReceived : .streamPartialReceived,
            outcome: .ready,
            workID: partial.metadata.workID,
            providerAttempt: partial.metadata.providerAttempt,
            durationMs: partial.latencyMs,
            requestedBackend: partial.metadata.requestedRoute,
            deliveredBackend: partial.route.deliveredKind,
            providerSequence: partial.providerSequence
        )

        guard predictionController.isCurrent(partial.metadata.workID),
              providerLifecycleGeneration == providerGeneration,
              let liveContext,
              contextGenerationTracker.matches(liveContext, signature: requestedSignature) else {
            streamedSuggestionCoordinator.recordRejectedBeforePolicy(partial)
            recordTrace(
                traceContext,
                event: .streamPartialIgnored,
                reason: liveContext == nil ? .staleTarget : .staleContext,
                outcome: .discarded,
                workID: partial.metadata.workID,
                providerAttempt: partial.metadata.providerAttempt,
                providerSequence: partial.providerSequence
            )
            if let streaming = currentSuggestion?.streamingMetadata,
               streaming.traceID == traceContext.traceID,
               streaming.workID == partial.metadata.workID {
                currentSuggestion = nil
                acceptanceSessionController.clearAll()
                presenter.hide()
            }
            return
        }

        let coalescedBefore = streamedSuggestionCoordinator.metrics.partialsCoalesced
        let decision = streamedSuggestionCoordinator.receive(
            partial,
            context: liveContext
        ) { [weak self] partial, text, context in
            self?.renderStreamedSuggestion(partial, text: text, context: context)
        }
        if streamedSuggestionCoordinator.metrics.partialsCoalesced > coalescedBefore {
            recordTrace(
                traceContext,
                event: .streamPartialCoalesced,
                outcome: .discarded,
                workID: partial.metadata.workID,
                providerAttempt: partial.metadata.providerAttempt,
                providerSequence: partial.providerSequence,
                partialCount: streamedSuggestionCoordinator.metrics.partialsCoalesced
            )
        }

        switch decision {
        case .render:
            break
        case .finalizeCurrent:
            markCurrentStreamFinished(partial, context: liveContext)
        case .keepCurrent:
            markCurrentStreamFinished(partial, context: liveContext)
            recordTrace(
                traceContext,
                event: .streamFinalSuppressed,
                outcome: .rejected,
                workID: partial.metadata.workID,
                providerSequence: partial.providerSequence
            )
        case .hide:
            recordTrace(
                traceContext,
                event: .streamFinalSuppressed,
                outcome: .rejected,
                workID: partial.metadata.workID,
                providerSequence: partial.providerSequence
            )
            currentSuggestion = nil
            acceptanceSessionController.clearAll()
            presenter.hide()
        case .ignore:
            recordTrace(
                traceContext,
                event: .streamPartialIgnored,
                outcome: .discarded,
                workID: partial.metadata.workID,
                providerAttempt: partial.metadata.providerAttempt,
                providerSequence: partial.providerSequence
            )
        }
    }

    private func renderStreamedSuggestion(
        _ partial: CompletionPartial,
        text: String,
        context: TextContext
    ) {
        guard predictionController.isCurrent(partial.metadata.workID) else { return }
        let traceContext = partial.metadata.traceContext
        let streamingMetadata = SuggestionStreamingMetadata(
            traceID: traceContext.traceID,
            workID: partial.metadata.workID,
            providerSequence: partial.providerSequence,
            isFinal: partial.isFinal
        )
        let updateExisting = currentSuggestion?.streamingMetadata.map {
            $0.traceID == streamingMetadata.traceID && $0.workID == streamingMetadata.workID
        } ?? false
        let suggestion = Suggestion(
            baseContextID: context.id,
            visibleText: text,
            traceContext: traceContext,
            streamingMetadata: streamingMetadata,
            rawText: partial.rawAccumulatedText,
            completionRoute: partial.route,
            latencyMs: partial.latencyMs
        )
        let result = publish(
            suggestion,
            context: context,
            traceContext: traceContext,
            recordForReuse: partial.isFinal,
            providerCallOccurred: true,
            streamingPartial: !partial.isFinal,
            updateExisting: updateExisting
        )
        if let overlayMs = result.overlayMs {
            streamedSuggestionCoordinator.recordOverlayCost(overlayMs)
        }
        let metrics = streamedSuggestionCoordinator.metrics
        recordTrace(
            traceContext,
            event: .streamPartialRendered,
            outcome: .published,
            workID: partial.metadata.workID,
            providerAttempt: partial.metadata.providerAttempt,
            durationMs: result.overlayMs,
            requestedBackend: partial.metadata.requestedRoute,
            deliveredBackend: partial.route.deliveredKind,
            providerSequence: partial.providerSequence,
            partialCount: metrics.partialsRendered,
            timeToFirstSafePartialMs: metrics.timeToFirstSafePartialMs,
            timeToFinalMs: metrics.timeToFinalMs
        )
    }

    private func markCurrentStreamFinished(_ partial: CompletionPartial, context: TextContext) {
        guard var suggestion = currentSuggestion,
              let streaming = suggestion.streamingMetadata,
              streaming.traceID == partial.metadata.traceContext.traceID,
              streaming.workID == partial.metadata.workID else { return }
        suggestion.streamingMetadata = SuggestionStreamingMetadata(
            traceID: streaming.traceID,
            workID: streaming.workID,
            providerSequence: partial.providerSequence,
            isFinal: true
        )
        currentSuggestion = suggestion
        acceptanceSessionController.recordPublication(context: context, suggestion: suggestion)
    }

    @discardableResult
    private func publish(
        _ suggestion: Suggestion,
        context: TextContext,
        latencyReport: CompletionLatencyReport? = nil,
        latencyStartedAt: ContinuousClock.Instant? = nil,
        traceContext suppliedTraceContext: CompletionTraceContext? = nil,
        recordForReuse: Bool = true,
        providerCallOccurred: Bool = true,
        streamingPartial: Bool = false,
        updateExisting: Bool = false
    ) -> SuggestionPublicationResult {
        let traceContext = suppliedTraceContext ?? suggestion.traceContext ?? startCompletionTrace()
        var tracedSuggestion = suggestion
        tracedSuggestion.traceContext = traceContext
        let mode = displayMode(for: context)
        let privacy = privacyStore.load()
        let privacyDecision = privacy.collectionDecision(
            appBundleID: context.app.bundleID,
            domain: context.domain
        )
        diagnostics.recordPrivacy(privacyDecision)
        let collectionAllowed = privacyDecision.allowed
        recordTrace(
            traceContext,
            event: .privacyGateDecided,
            outcome: collectionAllowed ? .allowed : .blocked
        )
        recordTrace(
            traceContext,
            event: .normalized,
            outcome: .ready,
            candidateCount: tracedSuggestion.alternatives.count,
            candidateRank: tracedSuggestion.selectedAlternativeIndex
        )
        GeometryDebug.log("suggestion-publication attempt context=\(debugContext(context)) mode=\(mode.rawValue) raw=\(debugSuggestionState(suggestion))")
        SuggestionPipelineLog.log("publication-attempt", fields: [
            "mode=\(mode.rawValue)",
            "collectionAllowed=\(collectionAllowed)",
            "context=\(SuggestionPipelineLog.contextDescription(context))",
            "suggestion=\(SuggestionPipelineLog.suggestionDescription(suggestion))"
        ])
        let result = publicationController.publish(
            tracedSuggestion,
            context: context,
            displayMode: mode,
            collectionAllowed: collectionAllowed,
            updateExisting: updateExisting
        )
        logPublicationResult(result)
        SuggestionPipelineLog.log("publication-result", fields: [
            "outcome=\(publicationOutcomeDescription(result.outcome))",
            "normalizationMs=\(result.normalizationMs ?? -1)",
            "overlayMs=\(result.overlayMs ?? -1)",
            "context=\(SuggestionPipelineLog.contextDescription(context))"
        ])

        var completedLatencyReport = latencyReport ?? CompletionLatencyReport()
        if providerCallOccurred, completedLatencyReport.backendMs == nil {
            completedLatencyReport.backendMs = result.lastLatencyMs
        }
        completedLatencyReport.normalizationMs = result.normalizationMs
        completedLatencyReport.overlayMs = result.overlayMs
        if completedLatencyReport.totalMs == nil, let latencyStartedAt {
            completedLatencyReport.totalMs = elapsedMs(since: latencyStartedAt)
        }
        if !streamingPartial { recordCompletionLatency(completedLatencyReport) }

        switch postProviderCoordinator.decidePublicationOutcome(result) {
        case .bindPublishedSuggestion(let suggestion):
            recordTrace(traceContext, event: .published, outcome: .published)
            recordTrace(traceContext, event: .overlayPresented, outcome: .ready)
            if !updateExisting { recordShownSuggestion() }
            if !streamingPartial {
                diagnostics.recordBackendSuccess(
                    rawText: suggestion.rawText,
                    normalizedText: suggestion.visibleText,
                    collectionAllowed: collectionAllowed,
                    route: suggestion.completionRoute
                )
            }
            var boundSuggestion = suggestion
            boundSuggestion.binding = SuggestionBinding.from(textContext: context)

            currentSuggestion = boundSuggestion
            acceptanceSessionController.recordPublication(context: context, suggestion: boundSuggestion)
            if recordForReuse {
                recordReusableCandidates(from: boundSuggestion, context: context)
            }
            consumePendingPostAcceptanceCommandIfNeeded()
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
        case .clearRejectedSuggestion(let reason):
            recordTrace(
                traceContext,
                event: .publicationRejected,
                reason: .publicationRejected,
                outcome: .rejected
            )
            finishTrace(traceContext, reason: .publicationRejected, outcome: .rejected)
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
        streamedSuggestionCoordinator.clear()
        if let traceContext = currentSuggestion?.traceContext {
            recordTrace(
                traceContext,
                event: .overlayHidden,
                reason: traceReason(for: reason),
                outcome: .discarded
            )
            finishTrace(traceContext, reason: traceReason(for: reason), outcome: .finished)
        }
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

    private func startCompletionTrace(
        parentTraceID: CompletionTraceID? = nil,
        originTraceID: CompletionTraceID? = nil,
        presentationAttempt: Int = 0
    ) -> CompletionTraceContext {
        if finishedTraceIDs.count >= 2_048 {
            finishedTraceIDs.removeAll(keepingCapacity: true)
        }
        let context = CompletionTraceContext(
            parentTraceID: parentTraceID,
            originTraceID: originTraceID,
            presentationAttempt: presentationAttempt
        )
        finishedTraceIDs.remove(context.traceID)
        return context
    }

    private func recordTrace(
        _ context: CompletionTraceContext,
        event: CompletionTraceEventName,
        reason: CompletionTraceReasonCode? = nil,
        outcome: CompletionTraceOutcome? = nil,
        workID: Int? = nil,
        providerAttempt: Int? = nil,
        durationMs: Int? = nil,
        requestedBackend: CompletionEngineKind? = nil,
        deliveredBackend: CompletionEngineKind? = nil,
        prefixUTF16Length: Int? = nil,
        suffixUTF16Length: Int? = nil,
        candidateCount: Int? = nil,
        candidateRank: Int? = nil,
        hostPublishOutcome: SuggestionSchedulingHostPublishOutcome? = nil,
        hostPublishMs: Int? = nil,
        hostPublishPollCount: Int? = nil,
        targetDebounceMs: Int? = nil,
        remainingDebounceMs: Int? = nil,
        schedulingReason: SuggestionSchedulingReason? = nil,
        recentBackendLatencyMs: Int? = nil,
        providerCallStarted: Bool? = nil,
        reuseSnapshotAgeBucket: Int? = nil,
        remainingCharacterBucket: Int? = nil,
        providerSequence: Int? = nil,
        partialCount: Int? = nil,
        timeToFirstSafePartialMs: Int? = nil,
        timeToFinalMs: Int? = nil,
        earlyAcceptance: Bool? = nil
    ) {
        completionTraceRecorder.record(CompletionTraceEvent(
            context: context,
            event: event,
            reason: reason,
            outcome: outcome,
            workID: workID,
            providerAttempt: providerAttempt,
            durationMs: durationMs,
            requestedBackend: requestedBackend,
            deliveredBackend: deliveredBackend,
            prefixUTF16Length: prefixUTF16Length,
            suffixUTF16Length: suffixUTF16Length,
            candidateCount: candidateCount,
            candidateRank: candidateRank,
            hostPublishOutcome: hostPublishOutcome,
            hostPublishMs: hostPublishMs,
            hostPublishPollCount: hostPublishPollCount,
            targetDebounceMs: targetDebounceMs,
            remainingDebounceMs: remainingDebounceMs,
            schedulingReason: schedulingReason,
            recentBackendLatencyMs: recentBackendLatencyMs,
            providerCallStarted: providerCallStarted,
            reuseSnapshotAgeBucket: reuseSnapshotAgeBucket,
            remainingCharacterBucket: remainingCharacterBucket,
            providerSequence: providerSequence,
            partialCount: partialCount,
            timeToFirstSafePartialMs: timeToFirstSafePartialMs,
            timeToFinalMs: timeToFinalMs,
            earlyAcceptance: earlyAcceptance
        ))
    }

    private func finishTrace(
        _ context: CompletionTraceContext,
        reason: CompletionTraceReasonCode,
        outcome: CompletionTraceOutcome
    ) {
        guard finishedTraceIDs.insert(context.traceID).inserted else {
            return
        }
        recordTrace(
            context,
            event: .traceFinished,
            reason: reason,
            outcome: outcome
        )
    }

    private func recordProviderTraceOutcome(
        _ outcome: SuggestionPipeline.Outcome<Suggestion>,
        traceContext: CompletionTraceContext,
        workID: Int,
        durationMs: Int?
    ) {
        switch outcome {
        case .publish(let suggestion):
            if let route = suggestion.completionRoute, route.usedFallback {
                recordTrace(
                    traceContext,
                    event: .providerFailed,
                    reason: .providerFailure,
                    outcome: .failed,
                    workID: workID,
                    providerAttempt: 0,
                    requestedBackend: route.requestedKind
                )
                recordTrace(
                    traceContext,
                    event: .fallbackStarted,
                    reason: .fallback,
                    outcome: .started,
                    workID: workID,
                    providerAttempt: 1,
                    requestedBackend: route.requestedKind,
                    deliveredBackend: route.deliveredKind
                )
                recordTrace(
                    traceContext,
                    event: .providerCompleted,
                    outcome: .ready,
                    workID: workID,
                    providerAttempt: 1,
                    durationMs: durationMs,
                    requestedBackend: route.requestedKind,
                    deliveredBackend: route.deliveredKind,
                    candidateCount: suggestion.alternatives.count,
                    candidateRank: suggestion.selectedAlternativeIndex
                )
            } else {
                recordTrace(
                    traceContext,
                    event: .providerCompleted,
                    outcome: .ready,
                    workID: workID,
                    providerAttempt: 0,
                    durationMs: durationMs,
                    requestedBackend: suggestion.completionRoute?.requestedKind,
                    deliveredBackend: suggestion.completionRoute?.deliveredKind,
                    candidateCount: suggestion.alternatives.count,
                    candidateRank: suggestion.selectedAlternativeIndex
                )
            }
        case .discard(let reason):
            recordTrace(
                traceContext,
                event: reason.kind == .cancelled ? .providerCancelled : .providerFailed,
                reason: reason.kind == .cancelled ? .taskCancelled : .staleWork,
                outcome: reason.kind == .cancelled ? .cancelled : .discarded,
                workID: workID,
                providerAttempt: 0,
                durationMs: durationMs
            )
        case .failure:
            recordTrace(
                traceContext,
                event: .providerFailed,
                reason: .providerFailure,
                outcome: .failed,
                workID: workID,
                providerAttempt: 0,
                durationMs: durationMs
            )
        case .continue:
            break
        }
    }

    private func traceReason(for reason: String) -> CompletionTraceReasonCode {
        if reason.contains("focus") {
            return .focusChanged
        }
        if reason.contains("stale") {
            return .staleContext
        }
        if reason.contains("acceptance") {
            return .acceptanceBlocked
        }
        if reason.contains("dismiss") {
            return .dismissed
        }
        if reason.contains("cancel") {
            return .taskCancelled
        }
        if reason.contains("diverg") {
            return .diverged
        }
        return .unknown
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
