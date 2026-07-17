@testable import AutoCompApp
import Foundation
import XCTest

final class TelemetryPrivacyTextTests: XCTestCase {
    func testPrivacySettingsDoesNotExposeTelemetrySharingAndProvidesLocalDebugExport() throws {
        let root = try packageRoot()
        let settingsSource = try settingsSourceContents(packageRoot: root)
        let privacyModelSource = try source(
            root: root,
            path: "Sources/AutoCompCore/Models/PrivacySettings.swift"
        )

        XCTAssertFalse(settingsSource.contains("Crash & error reporting"))
        XCTAssertFalse(settingsSource.contains("Share redacted crash and error telemetry"))
        XCTAssertFalse(settingsSource.contains("Delete Telemetry Data"))
        XCTAssertFalse(settingsSource.contains("privacyBinding(\\.telemetryEnabled)"))
        XCTAssertFalse(privacyModelSource.contains("telemetryEnabled"))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Sources/AutoCompCore/Services/TelemetryClient.swift").path
        ))
        XCTAssertTrue(settingsSource.contains("Section(\"Debug\")"))
        XCTAssertTrue(settingsSource.contains("Export Debug Logs..."))
        XCTAssertTrue(settingsSource.contains("Export Redacted Settings..."))
        XCTAssertTrue(settingsSource.contains("Import Redacted Settings..."))
        XCTAssertTrue(settingsSource.contains("controller.exportDebugLogs"))
        XCTAssertTrue(settingsSource.contains("controller.exportRedactedSettings"))
        XCTAssertTrue(settingsSource.contains("controller.redactedSettingsImportPreview"))
    }

}
