@testable import AutoCompApp
import Foundation
import XCTest

final class SettingsMicrocopyDensityTests: XCTestCase {
    func testPermissionCardsExposeShortActionsAndCollapseTechnicalDetails() throws {
        let settingsSource = try settingsSourceContents(packageRoot: packageRoot())

        XCTAssertTrue(settingsSource.contains("Section(\"Required access\")"))
        XCTAssertTrue(settingsSource.contains("Section(\"Optional access\")"))
        XCTAssertTrue(settingsSource.contains("title: \"Next step\""))
        XCTAssertTrue(settingsSource.contains("DisclosureGroup(\"Technical details\")"))
        XCTAssertTrue(settingsSource.contains("Button(\"Open System Settings\")"))
        XCTAssertTrue(settingsSource.contains("Open System Settings and enable AutoComp."))
        XCTAssertFalse(settingsSource.contains("Required before autocomplete can run."))
        XCTAssertFalse(settingsSource.contains("Relaunch required to apply this permission."))
    }

    func testPrivacyKeepsDensePolicyAndBackendDetailsCollapsed() throws {
        let settingsSource = try settingsSourceContents(packageRoot: packageRoot())

        XCTAssertTrue(settingsSource.contains("Used to write the suggestion you requested."))
        XCTAssertTrue(settingsSource.contains("Clipboard and visible screen text stay off until enabled."))
        XCTAssertTrue(settingsSource.contains("DisclosureGroup(\"Technical source policy\")"))
        XCTAssertTrue(settingsSource.contains("DisclosureGroup(\"Backend privacy details\")"))
        XCTAssertTrue(settingsSource.contains("backendPrivacySummary"))
        XCTAssertTrue(settingsSource.contains("Autocomplete text is sent to the configured remote backend."))
    }

    func testHealthRowsShowNextStepBeforeTechnicalDetails() throws {
        let root = try packageRoot()
        let healthSource = try String(
            contentsOf: root.appendingPathComponent("Sources/AutoCompApp/Views/HealthDashboardView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(healthSource.contains("let nextStep = nextStep(for: check)"))
        XCTAssertTrue(healthSource.contains("title: \"Next step\""))
        XCTAssertTrue(healthSource.contains("Text(\"Technical details\")"))
        XCTAssertTrue(healthSource.contains("nextStepTitle(for: action)"))
        XCTAssertFalse(healthSource.contains("Text(\"Details\")"))
    }

    func testHealthCheckSummariesLeadWithUserImpact() throws {
        let root = try packageRoot()
        let healthDirectory = root.appendingPathComponent("Sources/AutoCompApp/Health")
        let healthSource = try FileManager.default.contentsOfDirectory(
            at: healthDirectory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        .filter { $0.pathExtension == "swift" }
        .sorted { $0.path < $1.path }
        .map { try String(contentsOf: $0, encoding: .utf8) }
        .joined(separator: "\n")

        for requiredText in [
            "summary: \"Suggestions cannot attach yet.\"",
            "summary: \"Shortcut acceptance cannot run yet.\"",
            "summary: \"Visual context is off.\"",
            "summary: \"Completions may fail until it responds.\"",
            "summary = \"Automatic suggestions are on here.\"",
            "Technical cause:"
        ] {
            XCTAssertTrue(healthSource.contains(requiredText), "Missing health microcopy: \(requiredText)")
        }
    }

    private func packageRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url.deleteLastPathComponent()
        }

        throw XCTSkip("Unable to locate package root")
    }
}
