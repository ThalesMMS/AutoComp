import ApplicationServices
import AppKit
import CoreGraphics
import Foundation
import IOKit.hid

@MainActor
final class PermissionService: ObservableObject {
    @Published private(set) var accessibilityTrusted: Bool = false
    @Published private(set) var inputMonitoringAllowed: Bool = false
    @Published private(set) var inputMonitoringStatus: String = PermissionKind.inputMonitoring.baselineDescription
    @Published private(set) var screenRecordingAllowed: Bool = false
    @Published private(set) var screenRecordingNeedsRelaunch: Bool = false
    @Published private(set) var screenRecordingStatus: String = PermissionKind.screenRecording.baselineDescription
    @Published private(set) var runtimeBundleID: String = Bundle.main.bundleIdentifier ?? "unknown"
    @Published private(set) var runtimeExecutablePath: String = Bundle.main.executablePath ?? "unknown"

    private var refreshTimer: Timer?
    private var appActivationObserver: NSObjectProtocol?
    private var screenRecordingWasRequested: Bool = false
    private var lastLoggedPermissionState: PermissionDebugState?

    init() {
        refresh()
        startMonitoring()
    }

    isolated deinit {
        refreshTimer?.invalidate()
        if let appActivationObserver {
            NotificationCenter.default.removeObserver(appActivationObserver)
        }
    }

    var diagnostics: PermissionServiceDiagnostics {
        PermissionServiceDiagnostics(
            refreshTimerActive: refreshTimer != nil,
            appActivationObserverActive: appActivationObserver != nil
        )
    }

    func refresh() {
        accessibilityTrusted = AXIsProcessTrusted()
        inputMonitoringAllowed = hasInputMonitoringAccess()
        if inputMonitoringAllowed {
            inputMonitoringStatus = "Enabled"
        } else if inputMonitoringStatus != "Approve AutoComp in Privacy & Security > Input Monitoring." {
            inputMonitoringStatus = PermissionKind.inputMonitoring.baselineDescription
        }
        updateScreenRecordingStatus(preflightAllowed: CGPreflightScreenCaptureAccess())
        runtimeBundleID = Bundle.main.bundleIdentifier ?? "unknown"
        runtimeExecutablePath = Bundle.main.executablePath ?? "unknown"
        logPermissionStateIfNeeded()
    }

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibilityTrusted = AXIsProcessTrustedWithOptions(options)
    }

    func requestInputMonitoring() {
        NSApp.activate(ignoringOtherApps: true)
        inputMonitoringStatus = "Requesting Input Monitoring permission..."

        if CGPreflightListenEventAccess() {
            inputMonitoringAllowed = true
            inputMonitoringStatus = "Enabled"
        } else {
            // Creating a temporary event tap is the canonical way to trigger
            // the macOS Input Monitoring consent dialog, but a created tap is
            // not treated as proof that the global shortcut tap can run.
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
                callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
                userInfo: nil
            )

            if let tap {
                CFMachPortInvalidate(tap)
            }

            // Tap creation triggers the system prompt on first attempt.
            // Also try the IOKit path as a secondary trigger.
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)

            inputMonitoringAllowed = hasInputMonitoringAccess()
            if inputMonitoringAllowed {
                inputMonitoringStatus = "Enabled"
            } else {
                inputMonitoringAllowed = false
                inputMonitoringStatus = "Approve AutoComp in Privacy & Security > Input Monitoring."
                openInputMonitoringSettings()
            }
        }

        accessibilityTrusted = AXIsProcessTrusted()
        updateScreenRecordingStatus(preflightAllowed: CGPreflightScreenCaptureAccess())
        updateRuntimeIdentity()
        logPermissionStateIfNeeded()
    }

    func requestScreenRecording() {
        screenRecordingWasRequested = true
        let preflightBefore = CGPreflightScreenCaptureAccess()
        _ = CGRequestScreenCaptureAccess()
        let preflightAfter = CGPreflightScreenCaptureAccess()

        if preflightAfter {
            screenRecordingAllowed = true
            screenRecordingNeedsRelaunch = false
            screenRecordingStatus = "Enabled"
        } else {
            screenRecordingAllowed = false
            screenRecordingNeedsRelaunch = true
            screenRecordingStatus = "If AutoComp is enabled in System Settings, relaunch it to apply Screen Recording."
            if !preflightBefore {
                openScreenRecordingSettings()
            }
        }
        updateRuntimeIdentity()
        logPermissionStateIfNeeded()
    }

    var permissionPresentations: [PermissionPresentation] {
        PermissionKind.allCases.map { presentation(for: $0) }
    }

    func presentation(for kind: PermissionKind) -> PermissionPresentation {
        PermissionPresentationFactory.presentation(for: kind, state: stateSnapshot)
    }

    func request(_ kind: PermissionKind) {
        switch kind {
        case .accessibility:
            requestAccessibility()
        case .inputMonitoring:
            requestInputMonitoring()
        case .screenRecording:
            requestScreenRecording()
        }
    }

    func openSettings(for kind: PermissionKind) {
        NSWorkspace.shared.open(kind.settingsURL)
    }

    func openAccessibilitySettings() {
        openSettings(for: .accessibility)
    }

    func openInputMonitoringSettings() {
        openSettings(for: .inputMonitoring)
    }

    func openScreenRecordingSettings() {
        openSettings(for: .screenRecording)
    }

    func startMonitoring() {
        if refreshTimer == nil {
            refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
        }

        if appActivationObserver == nil {
            appActivationObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
        }
    }

    func stopMonitoring() {
        refreshTimer?.invalidate()
        refreshTimer = nil
        if let appActivationObserver {
            NotificationCenter.default.removeObserver(appActivationObserver)
            self.appActivationObserver = nil
        }
    }

    private func hasInputMonitoringAccess() -> Bool {
        InputMonitoringPermissionPolicy.isUsableForGlobalShortcuts(
            cgPreflightListenEventAccess: CGPreflightListenEventAccess(),
            ioHIDListenEventAccessGranted: IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        )
    }

    private func updateRuntimeIdentity() {
        runtimeBundleID = Bundle.main.bundleIdentifier ?? "unknown"
        runtimeExecutablePath = Bundle.main.executablePath ?? "unknown"
    }

    private func logPermissionStateIfNeeded() {
        let state = PermissionDebugState(
            accessibilityTrusted: accessibilityTrusted,
            inputMonitoringAllowed: inputMonitoringAllowed,
            screenRecordingAllowed: screenRecordingAllowed,
            runtimeBundleID: runtimeBundleID,
            runtimeExecutablePath: runtimeExecutablePath
        )
        guard state != lastLoggedPermissionState else {
            return
        }
        lastLoggedPermissionState = state
        GeometryDebug.log("permissions accessibility=\(state.accessibilityTrusted) inputMonitoring=\(state.inputMonitoringAllowed) screenRecording=\(state.screenRecordingAllowed) bundle=\(state.runtimeBundleID) executable=\(state.runtimeExecutablePath)")
    }

    private func updateScreenRecordingStatus(preflightAllowed: Bool) {
        screenRecordingAllowed = preflightAllowed
        if preflightAllowed {
            screenRecordingNeedsRelaunch = false
            screenRecordingWasRequested = false
            screenRecordingStatus = "Enabled"
        } else if screenRecordingWasRequested || screenRecordingNeedsRelaunch {
            screenRecordingNeedsRelaunch = true
            screenRecordingStatus = "If AutoComp is enabled in System Settings, relaunch it to apply Screen Recording."
        } else {
            screenRecordingStatus = PermissionKind.screenRecording.baselineDescription
        }
    }

    private var stateSnapshot: PermissionStateSnapshot {
        PermissionStateSnapshot(
            accessibilityTrusted: accessibilityTrusted,
            inputMonitoringAllowed: inputMonitoringAllowed,
            inputMonitoringStatus: inputMonitoringStatus,
            screenRecordingAllowed: screenRecordingAllowed,
            screenRecordingNeedsRelaunch: screenRecordingNeedsRelaunch,
            screenRecordingStatus: screenRecordingStatus
        )
    }
}

enum InputMonitoringPermissionPolicy {
    static func isUsableForGlobalShortcuts(
        cgPreflightListenEventAccess: Bool,
        ioHIDListenEventAccessGranted: Bool
    ) -> Bool {
        // KeyboardShortcutService starts only when CGPreflightListenEventAccess()
        // is true, so IOHIDCheckAccess alone must not turn the UI green.
        cgPreflightListenEventAccess
    }
}

private struct PermissionDebugState: Equatable {
    let accessibilityTrusted: Bool
    let inputMonitoringAllowed: Bool
    let screenRecordingAllowed: Bool
    let runtimeBundleID: String
    let runtimeExecutablePath: String
}

struct PermissionServiceDiagnostics: Equatable {
    let refreshTimerActive: Bool
    let appActivationObserverActive: Bool

    var activeObserverSetCount: Int {
        refreshTimerActive || appActivationObserverActive ? 1 : 0
    }
}
