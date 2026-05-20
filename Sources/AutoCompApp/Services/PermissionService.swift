import ApplicationServices
import AppKit
import CoreGraphics
import Foundation
import IOKit.hid

@MainActor
final class PermissionService: ObservableObject {
    @Published private(set) var accessibilityTrusted: Bool = false
    @Published private(set) var inputMonitoringAllowed: Bool = false
    @Published private(set) var inputMonitoringStatus: String = "Required for Tab and Right Shift acceptance."
    @Published private(set) var screenRecordingAllowed: Bool = false
    @Published private(set) var screenRecordingNeedsRelaunch: Bool = false
    @Published private(set) var screenRecordingStatus: String = "Optional; improves visible context capture."
    @Published private(set) var runtimeBundleID: String = Bundle.main.bundleIdentifier ?? "unknown"
    @Published private(set) var runtimeExecutablePath: String = Bundle.main.executablePath ?? "unknown"

    private var refreshTimer: Timer?
    private var screenRecordingWasRequested: Bool = false

    init() {
        refresh()
        startRefreshing()
    }

    isolated deinit {
        refreshTimer?.invalidate()
    }

    func refresh() {
        accessibilityTrusted = AXIsProcessTrusted()
        inputMonitoringAllowed = hasInputMonitoringAccess()
        if inputMonitoringAllowed {
            inputMonitoringStatus = "Enabled"
        } else if inputMonitoringStatus != "Approve AutoComp in Privacy & Security > Input Monitoring." {
            inputMonitoringStatus = "Required for Tab and Right Shift acceptance."
        }
        updateScreenRecordingStatus(preflightAllowed: CGPreflightScreenCaptureAccess())
        runtimeBundleID = Bundle.main.bundleIdentifier ?? "unknown"
        runtimeExecutablePath = Bundle.main.executablePath ?? "unknown"
    }

    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        accessibilityTrusted = AXIsProcessTrustedWithOptions(options)
    }

    func requestInputMonitoring() {
        NSApp.activate(ignoringOtherApps: true)
        inputMonitoringStatus = "Requesting Input Monitoring permission..."

        // Creating a temporary event tap is the canonical way to trigger
        // the macOS Input Monitoring consent dialog.
        if CGPreflightListenEventAccess() {
            inputMonitoringAllowed = true
            inputMonitoringStatus = "Enabled"
        } else {
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: CGEventMask(1 << CGEventType.keyDown.rawValue),
                callback: { _, _, event, _ in Unmanaged.passUnretained(event) },
                userInfo: nil
            )

            if let tap {
                // Tap created successfully — permission was granted.
                CFMachPortInvalidate(tap)
                inputMonitoringAllowed = true
                inputMonitoringStatus = "Enabled"
            } else {
                // Tap creation triggers the system prompt on first attempt.
                // Also try the IOKit path as a secondary trigger.
                _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
                inputMonitoringAllowed = false
                inputMonitoringStatus = "Approve AutoComp in Privacy & Security > Input Monitoring."
                openInputMonitoringSettings()
            }
        }

        accessibilityTrusted = AXIsProcessTrusted()
        updateScreenRecordingStatus(preflightAllowed: CGPreflightScreenCaptureAccess())
        updateRuntimeIdentity()
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

    private func startRefreshing() {
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
    }

    private func hasInputMonitoringAccess() -> Bool {
        CGPreflightListenEventAccess()
            || IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    private func updateRuntimeIdentity() {
        runtimeBundleID = Bundle.main.bundleIdentifier ?? "unknown"
        runtimeExecutablePath = Bundle.main.executablePath ?? "unknown"
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
            screenRecordingStatus = "Optional; improves visible context capture."
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
