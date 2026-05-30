import AppKit
import Foundation

@MainActor
final class SuggestionLifecycleController {
    // The fixed 0.28s polling timer was removed in favor of event-driven refresh triggers.

    private(set) var isRunning: Bool = false

    private var didActivateApplicationObserver: NSObjectProtocol?
    private var didDeactivateApplicationObserver: NSObjectProtocol?

    private let notificationCenter: NotificationCenter

    /// Called when we detect a likely focus change.
    var onFocusChanged: (@MainActor () -> Void)?

    /// Called when we detect the active/frontmost app has changed.
    var onActiveAppChanged: (@MainActor () -> Void)?

    /// Adaptive fallback scheduling: the engine can request a short-lived fallback refresh burst
    /// after focus/app changes to handle apps that don't emit useful AX notifications.
    var onFallbackTick: (@MainActor () -> Void)?

    private var fallbackTask: Task<Void, Never>?
    private var fallbackBurstGeneration: UInt64 = 0

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    func start() {
        stop(clearCallbacks: false)
        isRunning = true

        // Active app changes are a strong signal that our AX focus context needs to be re-resolved.
        didActivateApplicationObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else {
                    return
                }
                self.onActiveAppChanged?()
                // Activation almost always implies focus changes too.
                self.onFocusChanged?()
            }
        }

        // When the app deactivates, focus will likely change shortly after.
        didDeactivateApplicationObserver = notificationCenter.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isRunning else {
                    return
                }
                self.onFocusChanged?()
            }
        }
    }

    /// Start (or restart) a short-lived fallback refresh burst.
    ///
    /// This is intentionally not a constant-frequency timer for the full session.
    /// It runs a small number of ticks with exponential-ish backoff.
    func beginAdaptiveFallbackBurst() {
        guard isRunning else {
            return
        }

        fallbackBurstGeneration &+= 1
        let generation = fallbackBurstGeneration

        fallbackTask?.cancel()
        fallbackTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            // A few quick retries, then back off.
            let delaysNs: [UInt64] = [
                120_000_000, // 120ms
                250_000_000, // 250ms
                500_000_000, // 500ms
                500_000_000, // 500ms
                500_000_000, // 500ms
                1_000_000_000, // 1s
                2_000_000_000, // 2s
                2_000_000_000, // 2s
                2_000_000_000, // 2s
                500_000_000, // 500ms
                2_000_000_000, // 2s
                2_000_000_000 // 2s
            ]

            for delay in delaysNs {
                if Task.isCancelled {
                    return
                }

                try? await Task.sleep(nanoseconds: delay)

                guard self.isRunning, self.fallbackBurstGeneration == generation else {
                    return
                }

                self.onFallbackTick?()
            }
        }
    }

    func stop() {
        stop(clearCallbacks: true)
    }

    private func stop(clearCallbacks: Bool) {
        isRunning = false

        if let observer = didActivateApplicationObserver {
            notificationCenter.removeObserver(observer)
            didActivateApplicationObserver = nil
        }

        if let observer = didDeactivateApplicationObserver {
            notificationCenter.removeObserver(observer)
            didDeactivateApplicationObserver = nil
        }

        fallbackTask?.cancel()
        fallbackTask = nil

        if clearCallbacks {
            onFocusChanged = nil
            onActiveAppChanged = nil
            onFallbackTick = nil
        }
    }
}
