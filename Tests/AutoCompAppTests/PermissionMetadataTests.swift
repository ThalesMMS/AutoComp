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
            XCTAssertEqual(presentation.requirementTitle, kind.requirement.title)
            XCTAssertEqual(presentation.settingsLocation, kind.settingsLocation)
            XCTAssertTrue(presentation.isComplete)
        }
    }

    func testMissingRequiredPermissionsUseRequiredStatusTitle() {
        let state = PermissionStateSnapshot(
            accessibilityTrusted: false,
            inputMonitoringAllowed: false,
            inputMonitoringStatus: PermissionKind.inputMonitoring.baselineDescription,
            screenRecordingAllowed: false,
            screenRecordingNeedsRelaunch: false,
            screenRecordingStatus: PermissionKind.screenRecording.baselineDescription
        )

        let accessibility = PermissionPresentationFactory.presentation(for: .accessibility, state: state)
        let inputMonitoring = PermissionPresentationFactory.presentation(for: .inputMonitoring, state: state)

        XCTAssertEqual(accessibility.status, .missing)
        XCTAssertEqual(accessibility.statusTitle, "Required")
        XCTAssertEqual(accessibility.requirementDetail, "Blocking for focused text capture and insertion.")
        XCTAssertTrue(accessibility.message.contains("Privacy & Security > Accessibility"))
        XCTAssertEqual(
            accessibility.nextActionTitle,
            "Open Privacy & Security > Accessibility, enable AutoComp, then recheck."
        )
        XCTAssertEqual(inputMonitoring.status, .missing)
        XCTAssertEqual(inputMonitoring.statusTitle, "Required")
        XCTAssertEqual(inputMonitoring.requirementDetail, "Blocking for global shortcut acceptance.")
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
            screenRecordingStatus: PermissionKind.screenRecording.baselineDescription
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

    func testScreenRecordingIsOptionalForVisualContextAndOCRGeometryFallback() {
        let state = PermissionStateSnapshot(
            accessibilityTrusted: true,
            inputMonitoringAllowed: true,
            inputMonitoringStatus: "Enabled",
            screenRecordingAllowed: false,
            screenRecordingNeedsRelaunch: false,
            screenRecordingStatus: PermissionKind.screenRecording.baselineDescription
        )

        let presentation = PermissionPresentationFactory.presentation(for: .screenRecording, state: state)

        XCTAssertEqual(presentation.requirement, .optional)
        XCTAssertEqual(presentation.statusTitle, "Optional")
        XCTAssertEqual(presentation.requirementDetail, "Optional for visual context and OCR geometry fallback only.")
        XCTAssertTrue(presentation.message.contains("only needed for visual context or OCR geometry fallback"))
        XCTAssertEqual(
            presentation.nextActionTitle,
            "Open Privacy & Security > Screen Recording only if visual context or OCR geometry fallback is needed, enable AutoComp, then recheck."
        )
    }

    func testRevocationAndReauthorizationStatesStayUnambiguous() {
        let granted = PermissionPresentationFactory.presentation(
            for: .accessibility,
            state: PermissionStateSnapshot(
                accessibilityTrusted: true,
                inputMonitoringAllowed: true,
                inputMonitoringStatus: "Enabled",
                screenRecordingAllowed: false,
                screenRecordingNeedsRelaunch: false,
                screenRecordingStatus: PermissionKind.screenRecording.baselineDescription
            )
        )
        let revoked = PermissionPresentationFactory.presentation(
            for: .accessibility,
            state: PermissionStateSnapshot(
                accessibilityTrusted: false,
                inputMonitoringAllowed: true,
                inputMonitoringStatus: "Enabled",
                screenRecordingAllowed: false,
                screenRecordingNeedsRelaunch: false,
                screenRecordingStatus: PermissionKind.screenRecording.baselineDescription
            )
        )
        let reauthorized = PermissionPresentationFactory.presentation(
            for: .accessibility,
            state: PermissionStateSnapshot(
                accessibilityTrusted: true,
                inputMonitoringAllowed: true,
                inputMonitoringStatus: "Enabled",
                screenRecordingAllowed: false,
                screenRecordingNeedsRelaunch: false,
                screenRecordingStatus: PermissionKind.screenRecording.baselineDescription
            )
        )

        XCTAssertEqual(granted.status, .enabled)
        XCTAssertEqual(revoked.status, .missing)
        XCTAssertEqual(revoked.statusTitle, "Required")
        XCTAssertTrue(revoked.nextActionTitle.contains("then recheck"))
        XCTAssertEqual(reauthorized.status, .enabled)
        XCTAssertEqual(reauthorized.message, "Enabled for this app.")
    }

    func testPermissionPresentationsExposeActionsForEachPermissionType() {
        let state = PermissionStateSnapshot(
            accessibilityTrusted: false,
            inputMonitoringAllowed: false,
            inputMonitoringStatus: PermissionKind.inputMonitoring.baselineDescription,
            screenRecordingAllowed: false,
            screenRecordingNeedsRelaunch: false,
            screenRecordingStatus: PermissionKind.screenRecording.baselineDescription
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
