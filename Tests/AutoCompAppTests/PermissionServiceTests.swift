@testable import AutoCompApp
import Combine
import XCTest

@MainActor
final class PermissionServiceTests: XCTestCase {
    func testInputMonitoringPolicyDoesNotTreatIOHIDGrantAloneAsUsable() {
        XCTAssertFalse(
            InputMonitoringPermissionPolicy.isUsableForGlobalShortcuts(
                cgPreflightListenEventAccess: false,
                ioHIDListenEventAccessGranted: true
            )
        )
    }

    func testInputMonitoringPolicyMatchesGlobalShortcutEventTapPreflight() {
        XCTAssertTrue(
            InputMonitoringPermissionPolicy.isUsableForGlobalShortcuts(
                cgPreflightListenEventAccess: true,
                ioHIDListenEventAccessGranted: false
            )
        )
    }

    func testRequestInputMonitoringUsesSystemRequestResult() {
        let checker = FakePermissionAccessChecker()
        let service = PermissionService(accessChecker: checker)
        defer { service.stopMonitoring() }

        checker.requestInputMonitoringResult = true

        service.requestInputMonitoring()

        XCTAssertEqual(checker.requestInputMonitoringCallCount, 1)
        XCTAssertTrue(service.inputMonitoringAllowed)
        XCTAssertEqual(service.inputMonitoringStatus, "Enabled")
    }

    func testRefreshDoesNotPublishWhenPermissionStateIsUnchanged() {
        let checker = FakePermissionAccessChecker()
        let service = PermissionService(accessChecker: checker)
        service.stopMonitoring()

        var publishCount = 0
        let cancellable = service.objectWillChange.sink {
            publishCount += 1
        }

        service.refresh()
        XCTAssertEqual(publishCount, 0)

        checker.accessibilityTrusted = true
        service.refresh()

        XCTAssertEqual(publishCount, 1)
        cancellable.cancel()
    }
}

private final class FakePermissionAccessChecker: PermissionAccessChecking {
    var accessibilityTrusted = false
    var inputMonitoringAllowed = false
    var screenRecordingAllowed = false
    var requestAccessibilityResult = false
    var requestInputMonitoringResult = false
    var requestScreenRecordingResult = false
    private(set) var requestInputMonitoringCallCount = 0

    func isAccessibilityTrusted() -> Bool {
        accessibilityTrusted
    }

    func requestAccessibilityAccess() -> Bool {
        requestAccessibilityResult
    }

    func hasInputMonitoringAccess() -> Bool {
        inputMonitoringAllowed
    }

    func requestInputMonitoringAccess() -> Bool {
        requestInputMonitoringCallCount += 1
        return requestInputMonitoringResult
    }

    func hasScreenRecordingAccess() -> Bool {
        screenRecordingAllowed
    }

    func requestScreenRecordingAccess() -> Bool {
        requestScreenRecordingResult
    }
}
