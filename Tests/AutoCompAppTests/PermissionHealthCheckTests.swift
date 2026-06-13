@testable import AutoCompApp
import AutoCompCore
import XCTest

final class PermissionHealthCheckTests: XCTestCase {
    func testGrantedPermissionsUseSharedMetadataAndNoActions() {
        for kind in PermissionKind.allCases {
            let check = PermissionHealthCheck(kind: kind, isAllowed: true).evaluate()

            XCTAssertEqual(check.id, kind.healthCheckID)
            XCTAssertEqual(check.title, kind.title)
            XCTAssertEqual(check.status, .ok)
            XCTAssertEqual(check.summary, kind.healthGrantedSummary)
            XCTAssertEqual(check.details, kind.healthGrantedDetails)
            XCTAssertTrue(check.actions.isEmpty)
        }
    }

    func testMissingRequiredPermissionsFailWithPermissionSpecificActions() {
        let accessibility = PermissionHealthCheck(kind: .accessibility, isAllowed: false).evaluate()
        let inputMonitoring = PermissionHealthCheck(kind: .inputMonitoring, isAllowed: false).evaluate()

        XCTAssertEqual(accessibility.status, .fail)
        XCTAssertEqual(accessibility.summary, "Suggestions cannot attach yet.")
        XCTAssertEqual(
            accessibility.actions.map(\.id),
            [
                HealthRemediationCatalog.openAccessibilitySystemSettings.id,
                HealthRemediationCatalog.showAccessibilityInstructions.id
            ]
        )

        XCTAssertEqual(inputMonitoring.status, .fail)
        XCTAssertEqual(inputMonitoring.summary, "Shortcut acceptance cannot run yet.")
        XCTAssertEqual(
            inputMonitoring.actions.map(\.id),
            [
                HealthRemediationCatalog.openInputMonitoringSystemSettings.id,
                HealthRemediationCatalog.showInputMonitoringInstructions.id
            ]
        )
    }

    func testMissingScreenRecordingWarnsBecauseItIsOptional() {
        let check = PermissionHealthCheck(kind: .screenRecording, isAllowed: false).evaluate()

        XCTAssertEqual(check.status, .warn)
        XCTAssertEqual(check.summary, "Visual context is off.")
        XCTAssertEqual(
            check.actions.map(\.id),
            [
                HealthRemediationCatalog.openScreenRecordingSystemSettings.id,
                HealthRemediationCatalog.showScreenRecordingInstructions.id
            ]
        )
        XCTAssertTrue(check.details?.contains("Text-field suggestions still work") == true)
    }
}
