import AppKit
@testable import AutoCompApp
import XCTest

@MainActor
final class PermissionRecoveryTests: XCTestCase {
    func testGrantingInputMonitoringTwiceKeepsOneKeyboardTapSet() {
        let installer = RecordingKeyboardShortcutTapInstaller()
        let service = KeyboardShortcutService(tapInstaller: installer)

        service.start(onCommand: { _ in })

        XCTAssertEqual(service.diagnostics.activeTapCount, 3)
        XCTAssertEqual(service.diagnostics.activeTapSetCount, 1)
        XCTAssertEqual(installer.liveTapCount, 3)
        let firstTapSet = installer.installedTaps

        service.start(onCommand: { _ in })

        XCTAssertEqual(service.diagnostics.activeTapCount, 3)
        XCTAssertEqual(service.diagnostics.activeTapSetCount, 1)
        XCTAssertEqual(service.diagnostics.activeTapNames, ["hid", "session", "annotated-session"])
        XCTAssertEqual(installer.liveTapCount, 3)
        XCTAssertEqual(installer.installedTaps.count, 6)
        XCTAssertTrue(firstTapSet.allSatisfy(\.invalidated))
        XCTAssertTrue(firstTapSet.allSatisfy(\.removedFromRunLoop))
    }

    func testRevokingAndRegrantingInputMonitoringRestartsKeyboardTapSetOnce() {
        let installer = RecordingKeyboardShortcutTapInstaller()
        let service = KeyboardShortcutService(tapInstaller: installer)

        installer.permissionAllowed = true
        service.start(onCommand: { _ in })
        XCTAssertEqual(service.diagnostics.activeTapCount, 3)
        XCTAssertEqual(installer.liveTapCount, 3)

        installer.permissionAllowed = false
        service.start(onCommand: { _ in })
        XCTAssertEqual(service.diagnostics.activeTapCount, 0)
        XCTAssertEqual(installer.liveTapCount, 0)
        XCTAssertEqual(installer.installedTaps.count, 3)

        installer.permissionAllowed = true
        service.start(onCommand: { _ in })
        XCTAssertEqual(service.diagnostics.activeTapCount, 3)
        XCTAssertEqual(service.diagnostics.activeTapSetCount, 1)
        XCTAssertEqual(installer.liveTapCount, 3)
        XCTAssertEqual(installer.installedTaps.count, 6)
    }

    func testStopAndRelaunchClosePreviousKeyboardTapState() {
        let installer = RecordingKeyboardShortcutTapInstaller()
        let firstService = KeyboardShortcutService(tapInstaller: installer)
        firstService.start(onCommand: { _ in })
        XCTAssertEqual(installer.liveTapCount, 3)

        firstService.stop()
        XCTAssertEqual(firstService.diagnostics.activeTapCount, 0)
        XCTAssertEqual(firstService.diagnostics.activeTapSetCount, 0)
        XCTAssertFalse(firstService.diagnostics.handlersConfigured)
        XCTAssertEqual(installer.liveTapCount, 0)

        let secondService = KeyboardShortcutService(tapInstaller: installer)
        secondService.start(onCommand: { _ in })

        XCTAssertEqual(firstService.diagnostics.activeTapCount, 0)
        XCTAssertEqual(secondService.diagnostics.activeTapCount, 3)
        XCTAssertEqual(secondService.diagnostics.activeTapSetCount, 1)
        XCTAssertEqual(installer.liveTapCount, 3)
    }

    func testPermissionMonitoringDiagnosticsStaySingleSetAcrossRepeatedStartsAndStop() {
        let service = PermissionService()
        defer { service.stopMonitoring() }

        XCTAssertEqual(service.diagnostics.activeObserverSetCount, 1)
        XCTAssertTrue(service.diagnostics.refreshTimerActive)
        XCTAssertTrue(service.diagnostics.appActivationObserverActive)

        service.startMonitoring()
        service.startMonitoring()

        XCTAssertEqual(service.diagnostics.activeObserverSetCount, 1)
        XCTAssertTrue(service.diagnostics.refreshTimerActive)
        XCTAssertTrue(service.diagnostics.appActivationObserverActive)

        service.stopMonitoring()
        XCTAssertEqual(service.diagnostics.activeObserverSetCount, 0)
        XCTAssertFalse(service.diagnostics.refreshTimerActive)
        XCTAssertFalse(service.diagnostics.appActivationObserverActive)

        service.stopMonitoring()
        XCTAssertEqual(service.diagnostics.activeObserverSetCount, 0)

        service.startMonitoring()
        XCTAssertEqual(service.diagnostics.activeObserverSetCount, 1)
    }
}

private final class RecordingKeyboardShortcutTapInstaller: KeyboardShortcutTapInstalling {
    var permissionAllowed = true
    private(set) var installedTaps: [RecordingKeyboardShortcutTap] = []

    var liveTapCount: Int {
        installedTaps.filter { !$0.invalidated }.count
    }

    func hasInputMonitoringPermission() -> Bool {
        permissionAllowed
    }

    func installTap(
        location: CGEventTapLocation,
        name: String,
        eventsOfInterest: CGEventMask,
        callback: @escaping CGEventTapCallBack,
        userInfo: UnsafeMutableRawPointer
    ) -> KeyboardShortcutTap? {
        let tap = RecordingKeyboardShortcutTap(name: name)
        installedTaps.append(tap)
        return tap
    }
}

private final class RecordingKeyboardShortcutTap: KeyboardShortcutTap {
    let name: String
    private(set) var enabled = true
    private(set) var invalidated = false
    private(set) var removedFromRunLoop = false

    init(name: String) {
        self.name = name
    }

    func enable(_ enabled: Bool) {
        self.enabled = enabled
    }

    func invalidate() {
        invalidated = true
    }

    func removeFromRunLoop() {
        removedFromRunLoop = true
    }
}
