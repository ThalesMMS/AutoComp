@testable import AutoCompApp
import XCTest

final class PermissionMetadataTests: XCTestCase {
    func testEnabledStatusesUseSharedPresentation() {
        let state = PermissionStateSnapshot(
            accessibilityTrusted: true,
            inputMonitoringAllowed: true,
            inputMonitoringStatus: "Enabled",
            screenRecordingAllowed: true,
            screenRecordingNeedsRelaunch: false,
            screenRecordingStatus: "Enabled"
        )

        for kind in PermissionKind.allCases {
            let presentation = PermissionPresentationFactory.presentation(for: kind, state: state)
            XCTAssertEqual(presentation.status, .enabled)
            XCTAssertEqual(presentation.statusTitle, "Enabled")
            XCTAssertEqual(presentation.message, "Enabled for this app.")
            XCTAssertEqual(presentation.nextActionTitle, "No action needed.")
            XCTAssertTrue(presentation.isComplete)
        }
    }

    func testMissingRequiredPermissionsUseRequiredStatusTitle() {
        let state = PermissionStateSnapshot(
            accessibilityTrusted: false,
            inputMonitoringAllowed: false,
            inputMonitoringStatus: "Required for Tab and Right Shift acceptance.",
            screenRecordingAllowed: false,
            screenRecordingNeedsRelaunch: false,
            screenRecordingStatus: "Optional; improves visible context capture."
        )

        let accessibility = PermissionPresentationFactory.presentation(for: .accessibility, state: state)
        let inputMonitoring = PermissionPresentationFactory.presentation(for: .inputMonitoring, state: state)

        XCTAssertEqual(accessibility.status, .missing)
        XCTAssertEqual(accessibility.statusTitle, "Required")
        XCTAssertTrue(accessibility.message.contains("Privacy & Security > Accessibility"))
        XCTAssertEqual(
            accessibility.nextActionTitle,
            "Open Privacy & Security > Accessibility, enable AutoComp, then recheck."
        )
        XCTAssertEqual(inputMonitoring.status, .missing)
        XCTAssertEqual(inputMonitoring.statusTitle, "Required")
        XCTAssertTrue(inputMonitoring.message.contains("Privacy & Security > Input Monitoring"))
        XCTAssertEqual(
            inputMonitoring.nextActionTitle,
            "Open Privacy & Security > Input Monitoring, enable AutoComp, then recheck."
        )
    }

    func testRequestingInputMonitoringStatusIsPreserved() {
        let state = PermissionStateSnapshot(
            accessibilityTrusted: true,
            inputMonitoringAllowed: false,
            inputMonitoringStatus: "Requesting Input Monitoring permission...",
            screenRecordingAllowed: false,
            screenRecordingNeedsRelaunch: false,
            screenRecordingStatus: "Optional; improves visible context capture."
        )

        let presentation = PermissionPresentationFactory.presentation(for: .inputMonitoring, state: state)

        XCTAssertEqual(presentation.status, .requesting)
        XCTAssertEqual(presentation.statusTitle, "Requesting")
        XCTAssertEqual(
            presentation.message,
            "Waiting for approval in System Settings at Privacy & Security > Input Monitoring."
        )
        XCTAssertEqual(
            presentation.nextActionTitle,
            "Approve AutoComp in Privacy & Security > Input Monitoring, then recheck."
        )
    }

    func testScreenRecordingRelaunchStatusAndDeepLinkArePreserved() {
        let state = PermissionStateSnapshot(
            accessibilityTrusted: true,
            inputMonitoringAllowed: true,
            inputMonitoringStatus: "Enabled",
            screenRecordingAllowed: false,
            screenRecordingNeedsRelaunch: true,
            screenRecordingStatus: "If AutoComp is enabled in System Settings, relaunch it to apply Screen Recording."
        )

        let presentation = PermissionPresentationFactory.presentation(for: .screenRecording, state: state)

        XCTAssertEqual(presentation.status, .relaunchNeeded)
        XCTAssertEqual(presentation.statusTitle, "Relaunch Required")
        XCTAssertEqual(
            presentation.nextActionTitle,
            "Relaunch AutoComp after enabling Screen Recording."
        )
        XCTAssertTrue(presentation.needsRelaunch)
        XCTAssertEqual(
            presentation.settingsURL.absoluteString,
            "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        )
    }

    func testPermissionPresentationsExposeActionsForEachPermissionType() {
        let state = PermissionStateSnapshot(
            accessibilityTrusted: false,
            inputMonitoringAllowed: false,
            inputMonitoringStatus: "Required for Tab and Right Shift acceptance.",
            screenRecordingAllowed: false,
            screenRecordingNeedsRelaunch: false,
            screenRecordingStatus: "Optional; improves visible context capture."
        )

        for kind in PermissionKind.allCases {
            let presentation = PermissionPresentationFactory.presentation(for: kind, state: state)

            XCTAssertEqual(presentation.requestButtonTitle, kind.requestButtonTitle)
            XCTAssertEqual(presentation.openSettingsButtonTitle, kind.openSettingsButtonTitle)
            XCTAssertEqual(presentation.settingsURL, kind.settingsURL)
            XCTAssertFalse(presentation.nextActionTitle.isEmpty)
        }
    }
}
