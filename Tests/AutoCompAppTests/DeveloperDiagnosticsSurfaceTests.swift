import Foundation
import XCTest

final class DeveloperDiagnosticsSurfaceTests: XCTestCase {
    func testDeveloperSettingsCollectsAdvancedDiagnosticsAndTools() throws {
        let source = try developerSource()

        for requiredText in [
            "Section(\"Diagnostic launch flags\")",
            "Section(\"Overlay recovery\")",
            "Section(\"Backend diagnostics\")",
            "Section(\"Local runtime diagnostics\")",
            "Section(\"Apple Intelligence diagnostics\")",
            "Section(\"Focus and geometry\")",
            "Section(\"Prompt, output, and latency\")",
            "Section(\"AX capability snapshots\")",
            "Section(\"Runtime diagnostics\")",
            "FocusDebugOverlayOptions().isEnabled",
            "GeometryDebug.isEnabled",
            "RefreshDiagnostics.isEnabled",
            "SafeOverlayMode.isEnabled",
            "AUTOCOMP_CAPTURE_AX_CAPABILITY_SNAPSHOT",
            "engine.diagnostics.output.rawPreview",
            "engine.diagnostics.output.normalizedPreview",
            "engine.diagnostics.redactedLatencyReport()",
            "ForEach(engine.diagnostics.menuRows)"
        ] {
            XCTAssertTrue(source.contains(requiredText), "Missing Developer diagnostics surface text: \(requiredText)")
        }
    }

    func testDeveloperActionsConfirmDestructiveAndSettingsApplyFlows() throws {
        let developerSource = try developerSource()
        let setupSource = try sourceFile("Sources/AutoCompApp/Views/Settings/Sections/SetupSettingsView.swift")

        XCTAssertTrue(developerSource.contains(".confirmationDialog(\n            \"Delete Debug Artifacts?\""))
        XCTAssertTrue(developerSource.contains("isConfirmingDebugArtifactDeletion = true"))
        XCTAssertTrue(developerSource.contains(".confirmationDialog(\n            \"Apply Redacted Settings Import?\""))
        XCTAssertTrue(developerSource.contains("isConfirmingSettingsImport = true"))

        XCTAssertTrue(setupSource.contains(".confirmationDialog(\n            \"Clear Overlay Failure Count?\""))
        XCTAssertTrue(setupSource.contains("Button(\"Clear Overlay Failure Count\", role: .destructive)"))
        XCTAssertTrue(setupSource.contains("advisor.resetAdvancedOverlayFailures()"))
    }

    func testRedactedSettingsTransferExplainsExcludedSecretsAndPaths() throws {
        let source = try developerSource()

        for requiredText in [
            "Redacted exports exclude API keys",
            "local model paths",
            "debug artifacts",
            "prompt previews",
            "local file paths",
            "API keys and local paths are not included"
        ] {
            XCTAssertTrue(source.contains(requiredText), "Missing redacted transfer disclosure: \(requiredText)")
        }
    }

    func testCommonSettingsKeepDetailedDiagnosticsOutOfFirstLayer() throws {
        let modelSource = try sourceFile("Sources/AutoCompApp/Views/Settings/Sections/ModelSettingsView.swift")
        let privacySource = try sourceFile("Sources/AutoCompApp/Views/Settings/Sections/PrivacySettingsView.swift")
        let menuSource = try sourceFile("Sources/AutoCompApp/Views/MenuBarContentView.swift")

        XCTAssertFalse(modelSource.contains("Section(\"Local diagnostics\")"))
        XCTAssertFalse(modelSource.contains("Section(\"Apple Intelligence diagnostics\")"))
        XCTAssertFalse(modelSource.contains("LabeledContent(\"Last backend used\""))
        XCTAssertFalse(modelSource.contains("LabeledContent(\n                    \"Last local error\""))
        XCTAssertTrue(modelSource.contains("DisclosureGroup(\"Advanced backend details\")"))

        let technicalPolicyRange = try XCTUnwrap(privacySource.range(of: "DisclosureGroup(\"Technical source policy\")"))
        let localDiagnosticsRange = try XCTUnwrap(privacySource.range(of: "title: \"Local diagnostics\""))
        XCTAssertLessThan(
            privacySource.distance(from: privacySource.startIndex, to: technicalPolicyRange.lowerBound),
            privacySource.distance(from: privacySource.startIndex, to: localDiagnosticsRange.lowerBound)
        )

        XCTAssertFalse(menuSource.contains("ForEach(engine.diagnostics.menuRows)"))
        XCTAssertFalse(menuSource.contains("MenuStatusSnapshot.make"))
    }

    private func developerSource() throws -> String {
        try sourceFile("Sources/AutoCompApp/Views/Settings/Sections/DeveloperSettingsView.swift")
    }

    private func sourceFile(_ relativePath: String) throws -> String {
        try String(contentsOf: try packageRoot().appendingPathComponent(relativePath), encoding: .utf8)
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
