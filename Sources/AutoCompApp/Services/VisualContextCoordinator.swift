import AutoCompCore
import CoreGraphics
import Foundation

final class VisualContextCoordinator: StableFieldVisualContextProvider, VisualContextSessionClearing, @unchecked Sendable {
    var canAttemptCapture: Bool {
        // Non-invasive eligibility signal used for activation gating.
        // This does not attempt to capture; it only reflects whether capture could be attempted.
        screenCaptureAllowed()
    }

    private let privacyStore: PrivacySettingsStore
    private let visualTextCapturer: any VisualTextCapturing
    private let visualContextSummarizer: any VisualContextSummarizing
    private let screenCaptureAllowed: () -> Bool
    private let sessionTTL: TimeInterval
    private let now: () -> Date
    private let lock = NSLock()
    private var activeSession: VisualContextSession?

    init(
        privacyStore: PrivacySettingsStore,
        visualTextCapturer: any VisualTextCapturing = VisualContextOCRCapturer(),
        visualContextSummarizer: (any VisualContextSummarizing)? = nil,
        screenCaptureAllowed: @escaping () -> Bool = { CGPreflightScreenCaptureAccess() },
        maxSummaryCharacters: Int = 700,
        maxSummaryLines: Int = 12,
        sessionTTL: TimeInterval = 5,
        now: @escaping () -> Date = { Date() }
    ) {
        self.privacyStore = privacyStore
        self.visualTextCapturer = visualTextCapturer
        self.visualContextSummarizer = visualContextSummarizer ?? VisualContextSummarizer(
            maxCharacters: maxSummaryCharacters,
            maxLines: maxSummaryLines
        )
        self.screenCaptureAllowed = screenCaptureAllowed
        self.sessionTTL = max(0.25, sessionTTL)
        self.now = now
    }

    func currentVisualContext() async -> VisualContextSnapshot? {
        await currentVisualContext(for: nil)
    }

    func currentVisualContext(for stableFieldIdentity: StableFieldIdentity?) async -> VisualContextSnapshot? {
        let settings = privacyStore.load()
        guard settings.screenContextEnabled else {
            recordFailure(
                for: stableFieldIdentity,
                statusMessage: "Visual context disabled by privacy settings",
                logStatus: "disabled-by-privacy"
            )
            return nil
        }

        guard screenCaptureAllowed() else {
            recordFailure(
                for: stableFieldIdentity,
                statusMessage: "Screen Recording permission is off",
                logStatus: "screen-recording-off"
            )
            return nil
        }

        if let stableFieldIdentity,
           let cachedSnapshot = cachedReadySnapshot(for: stableFieldIdentity) {
            GeometryDebug.log("visual-context status=ready-cache source=visualContext-ocr stableField=\(Self.debugDescription(for: stableFieldIdentity))")
            return cachedSnapshot
        }

        if let stableFieldIdentity {
            beginSession(for: stableFieldIdentity)
        } else {
            GeometryDebug.log("visual-context status=unscoped-capture source=visualContext-ocr")
        }

        let observations = await visualTextCapturer.captureVisibleText()
        guard sessionStillCurrent(for: stableFieldIdentity) else {
            return nil
        }
        updateSession(for: stableFieldIdentity, state: .ocr)

        guard sessionStillCurrent(for: stableFieldIdentity) else {
            return nil
        }
        updateSession(for: stableFieldIdentity, state: .summarizing)

        guard let visualSummary = visualContextSummarizer.summarize(observations) else {
            recordFailure(
                for: stableFieldIdentity,
                statusMessage: "Visual context unavailable",
                logStatus: "empty"
            )
            return nil
        }

        if let stableFieldIdentity {
            GeometryDebug.log("visual-context source=visualContext-ocr stableField=\(Self.debugDescription(for: stableFieldIdentity))")
        }
        let snapshot = VisualContextSnapshot(
            summary: visualSummary.text,
            captureSources: visualSummary.captureSources,
            stableFieldIdentity: stableFieldIdentity
        )
        guard markReady(snapshot, for: stableFieldIdentity) else {
            return nil
        }
        return snapshot
    }

    func currentSession() -> VisualContextSession? {
        lock.lock()
        defer { lock.unlock() }
        return activeSession
    }

    func clearVisualContextSession() {
        lock.lock()
        let hadSession = activeSession != nil
        activeSession = nil
        lock.unlock()

        if hadSession {
            GeometryDebug.log("visual-context status=cleared reason=backend-switch")
        }
    }

    private func cachedReadySnapshot(for identity: StableFieldIdentity) -> VisualContextSnapshot? {
        lock.lock()
        defer { lock.unlock() }

        guard let activeSession,
              activeSession.identity == identity,
              activeSession.state == .ready,
              let snapshot = activeSession.snapshot else {
            return nil
        }

        guard now().timeIntervalSince(activeSession.updatedAt) <= sessionTTL else {
            self.activeSession = VisualContextSession(
                identity: identity,
                state: .expired,
                snapshot: activeSession.snapshot,
                statusMessage: "Visual context expired",
                updatedAt: now()
            )
            GeometryDebug.log("visual-context status=expired source=visualContext-ocr stableField=\(Self.debugDescription(for: identity))")
            return nil
        }

        return snapshot
    }

    private func beginSession(for identity: StableFieldIdentity) {
        lock.lock()
        activeSession = VisualContextSession(
            identity: identity,
            state: .capturing,
            statusMessage: "Capturing visual context",
            updatedAt: now()
        )
        lock.unlock()
        GeometryDebug.log("visual-context status=capturing source=visualContext-ocr stableField=\(Self.debugDescription(for: identity))")
    }

    private func updateSession(
        for identity: StableFieldIdentity?,
        state: VisualContextSessionState
    ) {
        guard let identity else {
            return
        }

        lock.lock()
        guard activeSession?.identity == identity else {
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

    private func markReady(_ snapshot: VisualContextSnapshot, for identity: StableFieldIdentity?) -> Bool {
        guard let identity else {
            GeometryDebug.log("visual-context status=ready-unscoped source=visualContext-ocr length=\(snapshot.summary.count)")
            return true
        }

        lock.lock()
        guard activeSession?.identity == identity else {
            lock.unlock()
            GeometryDebug.log("visual-context status=stale-field source=visualContext-ocr stableField=\(Self.debugDescription(for: identity))")
            return false
        }
        activeSession = VisualContextSession(
            identity: identity,
            state: .ready,
            snapshot: snapshot,
            statusMessage: "Visual context ready",
            updatedAt: now()
        )
        lock.unlock()
        GeometryDebug.log("visual-context status=ready source=visualContext-ocr stableField=\(Self.debugDescription(for: identity)) length=\(snapshot.summary.count)")
        return true
    }

    private func recordFailure(
        for identity: StableFieldIdentity?,
        statusMessage: String,
        logStatus: String
    ) {
        guard let identity else {
            GeometryDebug.log("visual-context status=\(logStatus) source=visualContext-ocr")
            return
        }

        lock.lock()
        activeSession = VisualContextSession(
            identity: identity,
            state: .failed,
            statusMessage: statusMessage,
            updatedAt: now()
        )
        lock.unlock()
        GeometryDebug.log("visual-context status=\(logStatus) source=visualContext-ocr stableField=\(Self.debugDescription(for: identity))")
    }

    private func sessionStillCurrent(for identity: StableFieldIdentity?) -> Bool {
        guard let identity else {
            return true
        }

        lock.lock()
        let isCurrent = activeSession?.identity == identity
        lock.unlock()

        if !isCurrent {
            GeometryDebug.log("visual-context status=stale-field source=visualContext-ocr stableField=\(Self.debugDescription(for: identity))")
        }
        return isCurrent
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
