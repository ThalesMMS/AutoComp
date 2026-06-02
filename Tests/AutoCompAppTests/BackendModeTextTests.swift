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
        XCTAssertTrue(readme.contains("Docs/ModelCompatibilityMatrix.md"))
        XCTAssertTrue(readme.contains("avoid recommending FIM optimized behavior"))
        XCTAssertTrue(readme.contains("AUTOCOMP_LOCAL_MODEL_PATH"))
        XCTAssertTrue(readme.contains("Settings > Model shows the local runtime state"))
    }

    func testSettingsTextExplainsConditionalLocalAndFallbackBehavior() throws {
        let root = try packageRoot()
        let settingsSource = try settingsSourceContents(packageRoot: root)
        let consentSource = try String(
            contentsOf: root.appendingPathComponent("Sources/AutoCompApp/Services/RemoteCompletionConsentStore.swift"),
            encoding: .utf8
        )
        let combinedSource = settingsSource + consentSource

        XCTAssertTrue(settingsSource.contains("Local in-process completion is usable only when this build includes the runtime"))
        XCTAssertTrue(settingsSource.contains("Apple Intelligence diagnostics"))
        XCTAssertTrue(settingsSource.contains("FoundationModels in the build SDK"))
        XCTAssertTrue(settingsSource.contains("Data leaves this Mac"))
        XCTAssertTrue(settingsSource.contains("Last backend used"))
        XCTAssertTrue(settingsSource.contains("Last local error"))
        XCTAssertTrue(settingsSource.contains("Remote fallback is enabled: if local completion fails"))
        XCTAssertTrue(settingsSource.contains("remote fallback is enabled after a local or Apple failure"))
        XCTAssertTrue(settingsSource.contains("Section(\"Remote completion consent\")"))
        XCTAssertTrue(settingsSource.contains("Section(\"Compatibility recommendation\")"))
        XCTAssertTrue(settingsSource.contains("Matrix guidance for request mode"))
        XCTAssertTrue(settingsSource.contains("FIM behavior"))
        XCTAssertTrue(settingsSource.contains("Endpoint type"))
        XCTAssertTrue(settingsSource.contains("Import GGUF"))
        XCTAssertTrue(settingsSource.contains("Clean Partial Downloads"))
        XCTAssertTrue(combinedSource.contains("Text from the active field may be sent"))
        XCTAssertTrue(settingsSource.contains("Reset Remote Completion Consent"))
    }

    func testCompletionProviderUsesRemoteConsentGate() throws {
        let environmentSource = try String(
            contentsOf: packageRoot().appendingPathComponent("Sources/AutoCompApp/App/AutoCompAppEnvironment.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(environmentSource.contains("RemoteCompletionConsentPolicy"))
        XCTAssertTrue(environmentSource.contains("remoteConsentStore: remoteCompletionConsentStore"))
        XCTAssertTrue(environmentSource.contains("remoteConsentChecker: usesInlinePreviewTestProvider"))
    }

    func testModelSettingsSeparatesProviderSelectionFromConditionalRemoteFields() throws {
        let settingsSource = try settingsSourceContents(packageRoot: packageRoot())
        let providerRange = try XCTUnwrap(settingsSource.range(of: "Section(\"Provider\")"))
        let consentRange = try XCTUnwrap(settingsSource.range(of: "Section(\"Remote completion consent\")"))
        let providerBlock = String(settingsSource[providerRange.lowerBound..<consentRange.lowerBound])

        XCTAssertTrue(providerBlock.contains("Picker(\"Selected backend\""))
        XCTAssertTrue(settingsSource.contains("switch draft.engineKind"))
        XCTAssertTrue(settingsSource.contains("private var remoteProviderFields"))
        XCTAssertTrue(settingsSource.contains("DisclosureGroup(\"Remote fallback provider\")"))
        XCTAssertFalse(settingsSource.contains("Section(\"Remote backend settings\")"))
        XCTAssertTrue(settingsSource.contains("Apple Intelligence fallback uses the remote backend settings above."))
        XCTAssertTrue(settingsSource.contains("Saved Apple Intelligence as the selected backend."))
    }

    func testPrivacySettingsTextReflectsActiveBackendDestination() throws {
        let settingsSource = try settingsSourceContents(packageRoot: packageRoot())

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
