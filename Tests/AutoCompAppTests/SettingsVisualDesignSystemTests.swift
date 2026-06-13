@testable import AutoCompApp
import Foundation
import XCTest

final class SettingsVisualDesignSystemTests: XCTestCase {
    func testSettingsVisualComponentsDeclareSharedStateAndAccessibility() throws {
        let source = try settingsSourceContents(packageRoot: packageRoot())

        for requiredText in [
            "enum SettingsVisualState",
            "case ok",
            "case warning",
            "case error",
            "case disabled",
            "case pending",
            "struct StatusBadge: View",
            "struct PermissionCard<Actions: View>: View",
            "struct SettingsInfoCard<Content: View>: View",
            "struct SettingsActionRow<Trailing: View>: View",
            "struct KeycapView: View",
            "struct KeyRecorderRow<Recorder: View>: View",
            "struct RemoteConsentSectionView: View",
            "struct SectionFooterNote: View",
            "struct DangerZoneView<Content: View>: View",
            ".accessibilityLabel(\"\\(state.title): \\(title)\")",
            ".accessibilityLabel(\"Shortcut \\(accessibilityLabel)\")"
        ] {
            XCTAssertTrue(source.contains(requiredText), "Missing Settings visual component contract: \(requiredText)")
        }
    }

    func testSettingsPanesUseSharedStateCardsBadgesAndKeycaps() throws {
        let root = try packageRoot()
        let settingsSource = try settingsSourceContents(packageRoot: root)
        let healthSource = try source(
            root: root,
            path: "Sources/AutoCompApp/Views/HealthDashboardView.swift"
        )
        let menuSource = try source(
            root: root,
            path: "Sources/AutoCompApp/Views/MenuBarContentView.swift"
        )

        for requiredText in [
            "PermissionCard(permission:",
            "SettingsVisualState.backend",
            "statusTitle: isAllowed ? \"Allowed\"",
            "SettingsVisualState.modelDownload",
            "KeyRecorderRow(",
            "KeycapView(binding:",
            "DangerZoneView("
        ] {
            XCTAssertTrue(settingsSource.contains(requiredText), "Missing shared visual usage: \(requiredText)")
        }

        XCTAssertTrue(healthSource.contains("SettingsInfoCard("))
        XCTAssertTrue(healthSource.contains("SettingsVisualState.health"))
        XCTAssertTrue(healthSource.contains("DisclosureGroup("))
        XCTAssertFalse(healthSource.contains("statusIndicator(for:"))
        XCTAssertTrue(menuSource.contains("StatusDot("))
    }

    func testRemoteConsentUIUsesSharedSectionComponent() throws {
        let root = try packageRoot()
        let settingsComponentsSource = try settingsSourceContents(packageRoot: root)
        let onboardingSource = try source(
            root: root,
            path: "Sources/AutoCompApp/Views/OnboardingView.swift"
        )

        XCTAssertTrue(settingsComponentsSource.contains("struct RemoteConsentSectionView: View"))
        XCTAssertTrue(settingsComponentsSource.contains("RemoteConsentSectionViewStyle"))
        XCTAssertTrue(settingsComponentsSource.contains("Allowed"))
        XCTAssertTrue(settingsComponentsSource.contains("Needs consent"))
        XCTAssertTrue(settingsComponentsSource.contains("Reset Remote Completion Consent"))
        XCTAssertTrue(settingsComponentsSource.contains("SettingsInfoCard("))

        XCTAssertTrue(settingsComponentsSource.contains("RemoteConsentSectionView("))
        XCTAssertTrue(onboardingSource.contains("RemoteConsentSectionView("))
        XCTAssertFalse(onboardingSource.contains("struct RemoteConsentCard"))
    }

    func testTechnicalDetailsUseDisclosureOrFooterNotes() throws {
        let root = try packageRoot()
        let settingsSource = try settingsSourceContents(packageRoot: root)
        let healthSource = try source(
            root: root,
            path: "Sources/AutoCompApp/Views/HealthDashboardView.swift"
        )

        XCTAssertTrue(settingsSource.contains("DisclosureGroup(\"Executable path\")"))
        XCTAssertTrue(settingsSource.contains("DisclosureGroup(\"Evidence details\")"))
        XCTAssertTrue(settingsSource.contains("DisclosureGroup(\"Runtime details\")"))
        XCTAssertTrue(settingsSource.contains("DisclosureGroup(\"Storage details\")"))
        XCTAssertTrue(settingsSource.contains("SectionFooterNote(text:"))
        XCTAssertTrue(healthSource.contains("DisclosureGroup("))
    }

}
