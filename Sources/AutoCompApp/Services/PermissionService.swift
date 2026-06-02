import ApplicationServices
import AppKit
import CoreGraphics
import Foundation
import IOKit.hid

protocol PermissionAccessChecking {
    func isAccessibilityTrusted() -> Bool
    func requestAccessibilityAccess() -> Bool
    func hasInputMonitoringAccess() -> Bool
    func requestInputMonitoringAccess() -> Bool
    func hasScreenRecordingAccess() -> Bool
    func requestScreenRecordingAccess() -> Bool
}

struct SystemPermissionAccessChecker: PermissionAccessChecking {
    func isAccessibilityTrusted() -> Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibilityAccess() -> Bool {
        let options = [
            "AXTrustedCheckOptionPrompt": true
        ] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func hasInputMonitoringAccess() -> Bool {
        InputMonitoringPermissionPolicy.isUsableForGlobalShortcuts(
            cgPreflightListenEventAccess: CGPreflightListenEventAccess(),
            ioHIDListenEventAccessGranted: IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        )
    }

    func requestInputMonitoringAccess() -> Bool {
        CGRequestListenEventAccess()
    }

    func hasScreenRecordingAccess() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func requestScreenRecordingAccess() -> Bool {
        CGRequestScreenCaptureAccess()
    }
}

@MainActor
final class PermissionService: ObservableObject {
    private static let inputMonitoringApprovalPrompt = "Approve AutoComp in Privacy & Security > Input Monitoring."

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
    private let accessChecker: PermissionAccessChecking

    init(accessChecker: PermissionAccessChecking = SystemPermissionAccessChecker()) {
        self.accessChecker = accessChecker
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
        setIfChanged(\.accessibilityTrusted, accessChecker.isAccessibilityTrusted())
        updateInputMonitoringStatus(allowed: accessChecker.hasInputMonitoringAccess())
        updateScreenRecordingStatus(preflightAllowed: accessChecker.hasScreenRecordingAccess())
        updateRuntimeIdentity()
        logPermissionStateIfNeeded()
    }

    func requestAccessibility() {
        setIfChanged(\.accessibilityTrusted, accessChecker.requestAccessibilityAccess())
    }

    func requestInputMonitoring() {
        if let app = NSApp {
            app.activate(ignoringOtherApps: true)
        }
        setIfChanged(\.inputMonitoringStatus, "Requesting Input Monitoring permission...")

        let requested = accessChecker.requestInputMonitoringAccess()
        let allowed = requested || accessChecker.hasInputMonitoringAccess()
        updateInputMonitoringStatus(allowed: allowed)
        if !allowed {
            setIfChanged(\.inputMonitoringStatus, Self.inputMonitoringApprovalPrompt)
            openInputMonitoringSettings()
        }

        setIfChanged(\.accessibilityTrusted, accessChecker.isAccessibilityTrusted())
        updateScreenRecordingStatus(preflightAllowed: accessChecker.hasScreenRecordingAccess())
        updateRuntimeIdentity()
        logPermissionStateIfNeeded()
    }

    func requestScreenRecording() {
        screenRecordingWasRequested = true
        let preflightBefore = accessChecker.hasScreenRecordingAccess()
        _ = accessChecker.requestScreenRecordingAccess()
        let preflightAfter = accessChecker.hasScreenRecordingAccess()

        if preflightAfter {
            setIfChanged(\.screenRecordingAllowed, true)
            setIfChanged(\.screenRecordingNeedsRelaunch, false)
            setIfChanged(\.screenRecordingStatus, "Enabled")
        } else {
            setIfChanged(\.screenRecordingAllowed, false)
            setIfChanged(\.screenRecordingNeedsRelaunch, true)
            setIfChanged(\.screenRecordingStatus, "If AutoComp is enabled in System Settings, relaunch it to apply Screen Recording.")
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
            let timer = Timer(timeInterval: 2.0, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.refresh()
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            refreshTimer = timer
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

    private func updateRuntimeIdentity() {
        setIfChanged(\.runtimeBundleID, Bundle.main.bundleIdentifier ?? "unknown")
        setIfChanged(\.runtimeExecutablePath, Bundle.main.executablePath ?? "unknown")
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

    private func updateInputMonitoringStatus(allowed: Bool) {
        setIfChanged(\.inputMonitoringAllowed, allowed)
        if allowed {
            setIfChanged(\.inputMonitoringStatus, "Enabled")
        } else if inputMonitoringStatus != Self.inputMonitoringApprovalPrompt {
            setIfChanged(\.inputMonitoringStatus, PermissionKind.inputMonitoring.baselineDescription)
        }
    }

    private func updateScreenRecordingStatus(preflightAllowed: Bool) {
        if preflightAllowed {
            setIfChanged(\.screenRecordingAllowed, true)
            screenRecordingWasRequested = false
            setIfChanged(\.screenRecordingNeedsRelaunch, false)
            setIfChanged(\.screenRecordingStatus, "Enabled")
        } else if screenRecordingWasRequested || screenRecordingNeedsRelaunch {
            setIfChanged(\.screenRecordingAllowed, false)
            setIfChanged(\.screenRecordingNeedsRelaunch, true)
            setIfChanged(\.screenRecordingStatus, "If AutoComp is enabled in System Settings, relaunch it to apply Screen Recording.")
        } else {
            setIfChanged(\.screenRecordingAllowed, false)
            setIfChanged(\.screenRecordingStatus, PermissionKind.screenRecording.baselineDescription)
        }
    }

    private func setIfChanged<Value: Equatable>(
        _ keyPath: ReferenceWritableKeyPath<PermissionService, Value>,
        _ value: Value
    ) {
        guard self[keyPath: keyPath] != value else {
            return
        }
        self[keyPath: keyPath] = value
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
