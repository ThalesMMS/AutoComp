@testable import AutoCompApp
import Foundation
import XCTest

final class TelemetryPrivacyTextTests: XCTestCase {
    func testPrivacySettingsDoesNotExposeTelemetrySharingAndProvidesLocalDebugExport() throws {
        let settingsSource = try String(
            contentsOf: try packageRoot().appendingPathComponent("Sources/AutoCompApp/Views/SettingsRootView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(settingsSource.contains("Crash & error reporting"))
        XCTAssertFalse(settingsSource.contains("Share redacted crash and error telemetry"))
        XCTAssertFalse(settingsSource.contains("Delete Telemetry Data"))
        XCTAssertFalse(settingsSource.contains("privacyBinding(\\.telemetryEnabled)"))
        XCTAssertTrue(settingsSource.contains("Section(\"Debug\")"))
        XCTAssertTrue(settingsSource.contains("Export Debug Logs..."))
        XCTAssertTrue(settingsSource.contains("Export Redacted Settings..."))
        XCTAssertTrue(settingsSource.contains("Import Redacted Settings..."))
        XCTAssertTrue(settingsSource.contains("controller.exportDebugLogs"))
        XCTAssertTrue(settingsSource.contains("controller.exportRedactedSettings"))
        XCTAssertTrue(settingsSource.contains("controller.redactedSettingsImportPreview"))
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
