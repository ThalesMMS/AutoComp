@testable import AutoCompApp
import XCTest

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
}
