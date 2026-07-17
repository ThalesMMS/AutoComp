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
            "SuggestionPipelineLog.isEnabled",
            "AUTOCOMP_PIPELINE_DEBUG=1",
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
        XCTAssertTrue(developerSource.contains(
            "This removes local debug bundles, completion traces, and prompt previews from this Mac."
        ))
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

    func testDeveloperDebugLogExportUsesSharedControllerFlowAndRefreshesCount() throws {
        let source = try developerSource()
        let exportRange = try XCTUnwrap(source.range(of: "private func exportDebugLogs()"))
        let nextFunctionRange = try XCTUnwrap(source.range(of: "\n    private func exportRedactedSettings", range: exportRange.upperBound..<source.endIndex))
        let exportBody = String(source[exportRange.lowerBound..<nextFunctionRange.lowerBound])

        XCTAssertTrue(exportBody.contains("controller.exportDebugLogsWithDirectoryPicker()"))
        XCTAssertTrue(exportBody.contains("debugArtifactCount = controller.debugArtifactCount()"))
        XCTAssertTrue(exportBody.contains("debugArtifactMessage = \"Debug logs exported to \\(exportURL.path).\""))
        XCTAssertFalse(exportBody.contains("NSOpenPanel"))
        XCTAssertFalse(exportBody.contains("withInteractionPipelineSuspended(reason: .settingsExport)"))
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

    func testHealthDashboardObservesHealthSnapshotService() throws {
        let healthSource = try sourceFile("Sources/AutoCompApp/Views/HealthDashboardView.swift")
        let appSource = try sourceFile("Sources/AutoCompApp/App/AutoCompApp.swift")

        XCTAssertTrue(healthSource.contains("@EnvironmentObject private var healthSnapshotService: HealthSnapshotService"))
        XCTAssertTrue(healthSource.contains("healthSnapshotService.snapshot"))
        XCTAssertTrue(healthSource.contains("healthSnapshotService.refresh()"))
        XCTAssertTrue(appSource.contains(".environmentObject(controller.healthSnapshotService)"))
    }

    private func developerSource() throws -> String {
        try sourceFile("Sources/AutoCompApp/Views/Settings/Sections/DeveloperSettingsView.swift")
    }

}
