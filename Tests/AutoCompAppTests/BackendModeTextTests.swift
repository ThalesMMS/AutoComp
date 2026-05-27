@testable import AutoCompApp
import Foundation
import XCTest

final class BackendModeTextTests: XCTestCase {
    func testReadmeDescribesBackendModesAndConditionalAvailability() throws {
        let readme = try String(
            contentsOf: packageRoot().appendingPathComponent("README.md"),
            encoding: .utf8
        )

        XCTAssertTrue(readme.contains("macOS 14+"))
        XCTAssertTrue(readme.contains("Remote OpenAI-compatible"))
        XCTAssertTrue(readme.contains("Apple Intelligence uses FoundationModels"))
        XCTAssertTrue(readme.contains("macOS 26"))
        XCTAssertTrue(readme.contains("Settings > Model shows Apple availability"))
        XCTAssertTrue(readme.contains("Local in-process is available only in app builds that link the optional llama.cpp runtime"))
        XCTAssertTrue(readme.contains("Remote fallback is opt-in"))
        XCTAssertTrue(readme.contains("last backend used for a completion"))
        XCTAssertTrue(readme.contains("Settings > Privacy repeats the active backend privacy summary"))
        XCTAssertTrue(readme.contains("AUTOCOMP_LOCAL_MODEL_PATH"))
        XCTAssertTrue(readme.contains("Settings > Model shows the local runtime state"))
    }

    func testSettingsTextExplainsConditionalLocalAndFallbackBehavior() throws {
        let settingsSource = try String(
            contentsOf: packageRoot().appendingPathComponent("Sources/AutoCompApp/Views/SettingsRootView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(settingsSource.contains("Local in-process completion is usable only when this build includes the runtime"))
        XCTAssertTrue(settingsSource.contains("Apple Intelligence diagnostics"))
        XCTAssertTrue(settingsSource.contains("FoundationModels in the build SDK"))
        XCTAssertTrue(settingsSource.contains("Data leaves this Mac"))
        XCTAssertTrue(settingsSource.contains("Last backend used"))
        XCTAssertTrue(settingsSource.contains("Last local error"))
        XCTAssertTrue(settingsSource.contains("Remote fallback is enabled: if local completion fails"))
        XCTAssertTrue(settingsSource.contains("remote fallback is enabled after a local or Apple failure"))
    }

    func testModelSettingsSeparatesBackendSelectionFromRemoteSettings() throws {
        let settingsSource = try String(
            contentsOf: packageRoot().appendingPathComponent("Sources/AutoCompApp/Views/SettingsRootView.swift"),
            encoding: .utf8
        )
        let selectionRange = try XCTUnwrap(settingsSource.range(of: "Section(\"Backend selection\")"))
        let remoteSettingsRange = try XCTUnwrap(settingsSource.range(of: "Section(\"Remote backend settings\")"))
        let selectionBlock = String(settingsSource[selectionRange.lowerBound..<remoteSettingsRange.lowerBound])

        XCTAssertTrue(selectionBlock.contains("Picker(\"Selected backend\""))
        XCTAssertFalse(selectionBlock.contains("Endpoint preset"))
        XCTAssertFalse(selectionBlock.contains("Base URL"))
        XCTAssertFalse(selectionBlock.contains("API key"))
        XCTAssertTrue(settingsSource.contains("These settings are used when Remote OpenAI-compatible is selected"))
        XCTAssertTrue(settingsSource.contains("Apple Intelligence fallback uses the remote backend settings above."))
        XCTAssertTrue(settingsSource.contains("Saved Apple Intelligence as the selected backend."))
    }

    func testPrivacySettingsTextReflectsActiveBackendDestination() throws {
        let settingsSource = try String(
            contentsOf: packageRoot().appendingPathComponent("Sources/AutoCompApp/Views/SettingsRootView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(settingsSource.contains("Section(\"Completion backend\")"))
        XCTAssertTrue(settingsSource.contains("Active engine"))
        XCTAssertTrue(settingsSource.contains("Request destination"))
        XCTAssertTrue(settingsSource.contains("Privacy controls limit optional local context"))
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
