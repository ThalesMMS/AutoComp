import AutoCompCore
import CoreGraphics
import Foundation

final class VisualContextCoordinator: StableFieldVisualContextProvider,
    TextContextVisualContextProvider,
    VisualContextSessionControlling,
    @unchecked Sendable
{
    var canAttemptCapture: Bool {
        sessionController.canAttemptCapture
    }

    private let sessionController: VisualContextSessionController

    init(
        privacyStore: PrivacySettingsStore,
        visualTextCapturer: any VisualTextCapturing = VisualContextOCRCapturer(),
        visualContextSummarizer: (any VisualContextSummarizing)? = nil,
        interactionPipelineSuspensionController: InteractionPipelineSuspensionController? = nil,
        screenCaptureAllowed: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
        maxSummaryCharacters: Int = 700,
        maxSummaryLines: Int = 12,
        sessionTTL: TimeInterval = 5,
        refreshInterval: TimeInterval = 4,
        captureTimeout: TimeInterval = 1.5,
        captureFailureCooldown: TimeInterval = 8,
        now: @escaping () -> Date = { Date() }
    ) {
        sessionController = VisualContextSessionController(
            privacyStore: privacyStore,
            visualTextCapturer: visualTextCapturer,
            visualContextSummarizer: visualContextSummarizer ?? VisualContextSummarizer(
                maxCharacters: maxSummaryCharacters,
                maxLines: maxSummaryLines
            ),
            interactionPipelineSuspensionController: interactionPipelineSuspensionController,
            screenCaptureAllowed: screenCaptureAllowed,
            sessionTTL: sessionTTL,
            refreshInterval: refreshInterval,
            captureTimeout: captureTimeout,
            captureFailureCooldown: captureFailureCooldown,
            now: now
        )
    }

    func currentVisualContext() async -> VisualContextSnapshot? {
        await sessionController.currentVisualContext()
    }

    func currentVisualContext(for stableFieldIdentity: StableFieldIdentity?) async -> VisualContextSnapshot? {
        await sessionController.currentVisualContext(for: stableFieldIdentity)
    }

    func currentVisualContext(for context: TextContext) async -> VisualContextSnapshot? {
        await sessionController.currentVisualContext(for: context)
    }

    func startIfEligible(for context: TextContext) {
        sessionController.startIfEligible(for: context)
    }

    func refreshOnFocusOrWindowChange(_ context: TextContext) {
        sessionController.refreshOnFocusOrWindowChange(context)
    }

    func refreshTick() {
        sessionController.refreshTick()
    }

    func stopAndClear() {
        sessionController.stopAndClear()
    }

    func currentSession() -> VisualContextSession? {
        sessionController.currentSession()
    }

    func clearVisualContextSession() {
        sessionController.clearVisualContextSession()
    }
}

final class VisualContextSessionController: @unchecked Sendable {
    var canAttemptCapture: Bool {
        screenCaptureAllowed() && !isCaptureFailureCooldownActive()
    }

    private let privacyStore: PrivacySettingsStore
    private let visualTextCapturer: any VisualTextCapturing
    private let visualContextSummarizer: any VisualContextSummarizing
    private let interactionPipelineSuspensionController: InteractionPipelineSuspensionController?
    private let screenCaptureAllowed: () -> Bool
    private let sessionTTL: TimeInterval
    private let refreshInterval: TimeInterval
    private let captureTimeout: TimeInterval
    private let captureFailureCooldown: TimeInterval
    private let now: () -> Date
    private let lock = NSLock()

    private var activeSession: VisualContextSession?
    private var targetContext: TextContext?
    private var inFlightTask: Task<Void, Never>?
    private var inFlightIdentity: StableFieldIdentity?
    private var lastRefreshStartedAt: Date?
    private var lastCaptureFailureAt: Date?

    init(
        privacyStore: PrivacySettingsStore,
        visualTextCapturer: any VisualTextCapturing,
        visualContextSummarizer: any VisualContextSummarizing,
        interactionPipelineSuspensionController: InteractionPipelineSuspensionController?,
        screenCaptureAllowed: @escaping () -> Bool,
        sessionTTL: TimeInterval,
        refreshInterval: TimeInterval,
        captureTimeout: TimeInterval,
        captureFailureCooldown: TimeInterval,
        now: @escaping () -> Date
    ) {
        self.privacyStore = privacyStore
        self.visualTextCapturer = visualTextCapturer
        self.visualContextSummarizer = visualContextSummarizer
        self.interactionPipelineSuspensionController = interactionPipelineSuspensionController
        self.screenCaptureAllowed = screenCaptureAllowed
        self.sessionTTL = max(0.25, sessionTTL)
        self.refreshInterval = max(1, refreshInterval)
        self.captureTimeout = max(0.05, captureTimeout)
        self.captureFailureCooldown = max(0, captureFailureCooldown)
        self.now = now
    }

    func currentVisualContext() async -> VisualContextSnapshot? {
        cachedSnapshotMatching { _ in true }
    }

    func currentVisualContext(for stableFieldIdentity: StableFieldIdentity?) async -> VisualContextSnapshot? {
        guard let stableFieldIdentity else {
            GeometryDebug.log("visual-context status=cache-miss source=visualContext-ocr stableField=nil")
            return nil
        }
        return cachedSnapshotMatching { session in
            session.identity.matchesStableTarget(stableFieldIdentity)
        }
    }

    func currentVisualContext(for context: TextContext) async -> VisualContextSnapshot? {
        if let blocked = captureBlock(for: context) {
            recordFailure(for: context, statusMessage: blocked.statusMessage, logStatus: blocked.logStatus)
            return nil
        }

        let identity = sessionIdentity(for: context)
        return cachedSnapshotMatching { session in
            session.identity.matchesStableTarget(identity)
        }
    }

    func startIfEligible(for context: TextContext) {
        scheduleCapture(for: context, force: false, reason: "start")
    }

    func refreshOnFocusOrWindowChange(_ context: TextContext) {
        let identity = sessionIdentity(for: context)
        let shouldRefresh = lock.withLock {
            guard let targetContext else {
                return true
            }
            return !sessionIdentity(for: targetContext).matchesStableTarget(identity)
        }

        if shouldRefresh {
            scheduleCapture(for: context, force: true, reason: "focus-window-change")
        } else {
            lock.withLock {
                targetContext = context
            }
            GeometryDebug.log("visual-context status=focus-window-unchanged source=visualContext-ocr stableField=\(Self.debugDescription(for: identity))")
        }
    }

    func refreshTick() {
        let context = lock.withLock { targetContext }
        guard let context else {
            return
        }

        let currentTime = now()
        let shouldRefresh = lock.withLock {
            guard let lastRefreshStartedAt else {
                return true
            }
            return currentTime.timeIntervalSince(lastRefreshStartedAt) >= refreshInterval
        }
        guard shouldRefresh else {
            return
        }

        scheduleCapture(for: context, force: true, reason: "timer")
    }

    func stopAndClear() {
        clear(reason: "stop")
    }

    func clearVisualContextSession() {
        clear(reason: "backend-switch")
    }

    func currentSession() -> VisualContextSession? {
        lock.withLock {
            activeSession
        }
    }

    private func scheduleCapture(for context: TextContext, force: Bool, reason: String) {
        if let blocked = captureBlock(for: context) {
            recordFailure(for: context, statusMessage: blocked.statusMessage, logStatus: blocked.logStatus)
            return
        }

        let identity = sessionIdentity(for: context)
        let task: Task<Void, Never>? = lock.withLock {
            targetContext = context

            if !force,
               let activeSession,
               activeSession.identity.matchesStableTarget(identity),
               activeSession.state == .ready,
               !isExpired(activeSession) {
                GeometryDebug.log("visual-context status=ready-cache source=visualContext-ocr stableField=\(Self.debugDescription(for: identity))")
                return nil
            }

            if !force,
               inFlightIdentity?.matchesStableTarget(identity) == true,
               inFlightTask != nil {
                GeometryDebug.log("visual-context status=in-flight-cache source=visualContext-ocr stableField=\(Self.debugDescription(for: identity))")
                return nil
            }

            inFlightTask?.cancel()
            activeSession = VisualContextSession(
                identity: identity,
                state: .capturing,
                statusMessage: "Capturing visual context",
                updatedAt: now()
            )
            inFlightIdentity = identity
            lastRefreshStartedAt = now()
            let task = Task { [weak self] in
                guard let self else {
                    return
                }
                await self.capture(context: context, identity: identity, reason: reason)
            }
            inFlightTask = task
            return task
        }

        if task != nil {
            GeometryDebug.log("visual-context status=capturing reason=\(reason) source=visualContext-ocr stableField=\(Self.debugDescription(for: identity))")
        }
    }

    private func capture(context: TextContext, identity: StableFieldIdentity, reason: String) async {
        updateSession(for: identity, state: .ocr)
        let captureResult = await AsyncTimeout.run(
            seconds: captureTimeout,
            onTimeout: {
                GeometryDebug.log("visual-context status=capture-timeout source=visualContext-ocr")
            },
            operation: { [visualTextCapturer] in
                await visualTextCapturer.captureVisibleText()
            }
        )
        let observations: [VisualTextObservation]
        switch captureResult {
        case .completed(let capturedObservations):
            observations = capturedObservations
        case .timedOut:
            recordCaptureFailure()
            recordFailure(
                for: context,
                statusMessage: "Visual context timed out",
                logStatus: "capture-timeout"
            )
            return
        }
        guard !Task.isCancelled,
              sessionStillCurrent(for: identity) else {
            return
        }

        updateSession(for: identity, state: .summarizing)
        guard let visualSummary = visualContextSummarizer.summarize(
            observations,
            excludingFieldText: fieldTextCandidates(from: context)
        ) else {
            recordFailure(
                for: context,
                statusMessage: "Visual context unavailable",
                logStatus: "empty"
            )
            return
        }

        let snapshot = VisualContextSnapshot(
            summary: visualSummary.text,
            captureSources: visualSummary.captureSources,
            createdAt: now(),
            stableFieldIdentity: context.stableFieldIdentity
        )
        markReady(snapshot, for: identity, reason: reason)
    }

    private func cachedSnapshotMatching(
        _ matches: (VisualContextSession) -> Bool
    ) -> VisualContextSnapshot? {
        lock.lock()
        guard let activeSession,
              matches(activeSession),
              activeSession.state == .ready,
              let snapshot = activeSession.snapshot else {
            lock.unlock()
            GeometryDebug.log("visual-context status=cache-miss source=visualContext-ocr")
            return nil
        }

        if isExpired(activeSession) {
            self.activeSession = VisualContextSession(
                identity: activeSession.identity,
                state: .expired,
                snapshot: activeSession.snapshot,
                statusMessage: "Visual context expired",
                updatedAt: now()
            )
            lock.unlock()
            GeometryDebug.log("visual-context status=expired source=visualContext-ocr stableField=\(Self.debugDescription(for: activeSession.identity))")
            return nil
        }

        lock.unlock()
        GeometryDebug.log("visual-context status=ready-cache source=visualContext-ocr stableField=\(Self.debugDescription(for: activeSession.identity))")
        return snapshot
    }

    private func captureBlock(for context: TextContext) -> (statusMessage: String, logStatus: String)? {
        if interactionPipelineSuspensionController?.isSuspended == true {
            return ("Visual context paused", "pipeline-suspended")
        }

        guard privacyStore.load().screenContextEnabled else {
            return ("Visual context disabled by privacy settings", "disabled-by-privacy")
        }

        guard screenCaptureAllowed() else {
            return ("Screen Recording permission is off", "screen-recording-off")
        }

        guard !isCaptureFailureCooldownActive() else {
            return ("Visual context cooling down after capture timeout", "capture-cooldown")
        }

        guard context.captureSources != [.keystrokeBufferLowTrust] else {
            return ("Visual context unavailable for low-trust input", "low-trust")
        }

        return nil
    }

    private func recordFailure(
        for context: TextContext,
        statusMessage: String,
        logStatus: String
    ) {
        recordFailure(
            for: sessionIdentity(for: context),
            statusMessage: statusMessage,
            logStatus: logStatus
        )
    }

    private func recordFailure(
        for identity: StableFieldIdentity,
        statusMessage: String,
        logStatus: String
    ) {
        let taskToCancel = lock.withLock {
            let task = inFlightTask
            inFlightTask = nil
            inFlightIdentity = nil
            activeSession = VisualContextSession(
                identity: identity,
                state: .failed,
                statusMessage: statusMessage,
                updatedAt: now()
            )
            return task
        }
        taskToCancel?.cancel()
        GeometryDebug.log("visual-context status=\(logStatus) source=visualContext-ocr stableField=\(Self.debugDescription(for: identity))")
    }

    private func updateSession(for identity: StableFieldIdentity, state: VisualContextSessionState) {
        lock.lock()
        guard activeSession?.identity.matchesStableTarget(identity) == true else {
            lock.unlock()
            return
        }
        activeSession = VisualContextSession(
            identity: identity,
            state: state,
            snapshot: activeSession?.snapshot,
            statusMessage: state.rawValue,
            updatedAt: now()
        )
        lock.unlock()
        GeometryDebug.log("visual-context status=\(state.rawValue) source=visualContext-ocr stableField=\(Self.debugDescription(for: identity))")
    }

    private func markReady(_ snapshot: VisualContextSnapshot, for identity: StableFieldIdentity, reason: String) {
        lock.lock()
        guard activeSession?.identity.matchesStableTarget(identity) == true else {
            lock.unlock()
            GeometryDebug.log("visual-context status=stale-field source=visualContext-ocr stableField=\(Self.debugDescription(for: identity))")
            return
        }
        activeSession = VisualContextSession(
            identity: identity,
            state: .ready,
            snapshot: snapshot,
            statusMessage: "Visual context ready",
            updatedAt: now()
        )
        inFlightTask = nil
        inFlightIdentity = nil
        lock.unlock()
        clearCaptureFailure()
        GeometryDebug.log("visual-context status=ready reason=\(reason) source=visualContext-ocr stableField=\(Self.debugDescription(for: identity)) length=\(snapshot.summary.count)")
    }

    private func isCaptureFailureCooldownActive() -> Bool {
        lock.withLock {
            guard captureFailureCooldown > 0,
                  let lastCaptureFailureAt else {
                return false
            }
            return now().timeIntervalSince(lastCaptureFailureAt) < captureFailureCooldown
        }
    }

    private func recordCaptureFailure() {
        guard captureFailureCooldown > 0 else {
            return
        }
        lock.withLock {
            lastCaptureFailureAt = now()
        }
    }

    private func clearCaptureFailure() {
        lock.withLock {
            lastCaptureFailureAt = nil
        }
    }

    private func sessionStillCurrent(for identity: StableFieldIdentity) -> Bool {
        let isCurrent = lock.withLock {
            activeSession?.identity.matchesStableTarget(identity) == true
        }

        if !isCurrent {
            GeometryDebug.log("visual-context status=stale-field source=visualContext-ocr stableField=\(Self.debugDescription(for: identity))")
        }
        return isCurrent
    }

    private func clear(reason: String) {
        let cleared = lock.withLock {
            let hadSession = activeSession != nil || inFlightTask != nil
            let task = inFlightTask
            activeSession = nil
            targetContext = nil
            inFlightTask = nil
            inFlightIdentity = nil
            lastRefreshStartedAt = nil
            return (hadSession, task)
        }
        cleared.1?.cancel()
        if cleared.0 {
            GeometryDebug.log("visual-context status=cleared reason=\(reason)")
        }
    }

    private func isExpired(_ session: VisualContextSession) -> Bool {
        now().timeIntervalSince(session.updatedAt) > sessionTTL
    }

    private func sessionIdentity(for context: TextContext) -> StableFieldIdentity {
        context.stableFieldIdentity ?? StableFieldIdentity(
            app: context.app,
            domain: context.domain,
            focusedElementFrame: context.focusedElementRect
        )
    }

    private func fieldTextCandidates(from context: TextContext) -> [String] {
        [
            context.fullTextWindow,
            context.textBeforeCursor + (context.textAfterCursor ?? ""),
            context.textBeforeCursor,
            context.textAfterCursor,
            context.selectedText
        ]
        .compactMap { $0 }
        .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    }

    private static func debugDescription(for identity: StableFieldIdentity) -> String {
        [
            "bundle=\(identity.bundleID)",
            "pid=\(identity.processID)",
            "domain=\(identity.domain ?? "nil")",
            "role=\(identity.role ?? "nil")",
            "subrole=\(identity.subrole ?? "nil")",
            "frame=\(String(describing: identity.roundedFocusedElementFrame))",
            "seq=\(String(describing: identity.focusChangeSequence))"
        ].joined(separator: " ")
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}
