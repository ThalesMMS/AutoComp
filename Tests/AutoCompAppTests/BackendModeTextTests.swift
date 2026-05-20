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
        XCTAssertTrue(readme.contains("Local in-process is available only in app builds that link the optional llama.cpp runtime"))
        XCTAssertTrue(readme.contains("AUTOCOMP_LOCAL_MODEL_PATH"))
        XCTAssertTrue(readme.contains("Settings > Model shows the local runtime state"))
    }

    func testSettingsTextExplainsConditionalLocalAndFallbackBehavior() throws {
        let settingsSource = try String(
            contentsOf: packageRoot().appendingPathComponent("Sources/AutoCompApp/Views/SettingsRootView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(settingsSource.contains("Local in-process completion is usable only when this build includes the runtime"))
        XCTAssertTrue(settingsSource.contains("remote fallback is enabled after a local or Apple failure"))
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
