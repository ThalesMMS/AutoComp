@testable import AutoCompApp
import Foundation
import XCTest

final class PrivacyPolicyTextTests: XCTestCase {
    func testPrivacySettingsExposeSourcePolicyDomainRulesAndDeleteAll() throws {
        let settingsSource = try String(
            contentsOf: try packageRoot().appendingPathComponent("Sources/AutoCompApp/Views/SettingsRootView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(settingsSource.contains("Section(\"Source policy\")"))
        XCTAssertTrue(settingsSource.contains("AX text"))
        XCTAssertTrue(settingsSource.contains("Clipboard"))
        XCTAssertTrue(settingsSource.contains("Screen OCR"))
        XCTAssertTrue(settingsSource.contains("Debug logs"))
        XCTAssertTrue(settingsSource.contains("Section(\"Local metrics\")"))
        XCTAssertTrue(settingsSource.contains("Keep local productivity counters"))
        XCTAssertTrue(settingsSource.contains("Reset Productivity Metrics"))
        XCTAssertTrue(settingsSource.contains("Counters are stored locally as numbers only"))
        XCTAssertTrue(settingsSource.contains("Remote backend"))
        XCTAssertTrue(settingsSource.contains("Domain collection rules"))
        XCTAssertTrue(settingsSource.contains("PrivacySettings.normalizedDomain"))
        XCTAssertTrue(settingsSource.contains("Delete All Local Privacy Data"))
        XCTAssertTrue(settingsSource.contains("remoteBackendExposure(sourceEnabled: settings.clipboardContextEnabled)"))
        XCTAssertTrue(settingsSource.contains("remoteBackendExposure(sourceEnabled: settings.screenContextEnabled)"))
    }

    func testPrivacyDocumentationCoversSourceLimitsAndDeletion() throws {
        let root = try packageRoot()
        let document = try String(
            contentsOf: root.appendingPathComponent("Docs/PrivacyPolicy.md"),
            encoding: .utf8
        )
        let readme = try String(
            contentsOf: root.appendingPathComponent("README.md"),
            encoding: .utf8
        )

        XCTAssertTrue(document.contains("| AX text | On while autocomplete is enabled | Completion request |"))
        XCTAssertTrue(document.contains("| Clipboard | Off | Optional context |"))
        XCTAssertTrue(document.contains("| Screen OCR | Off | Visual context and geometry fallback |"))
        XCTAssertTrue(document.contains("| Debug logs | Sensitive content off | Diagnostics | No |"))
        XCTAssertTrue(document.contains("| Productivity metrics | On | Local value feedback | No |"))
        XCTAssertTrue(document.contains("Domain privacy rules do not silently change the selected completion backend."))
        XCTAssertTrue(document.contains("resets productivity metrics"))
        XCTAssertTrue(readme.contains("local productivity metrics"))
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
