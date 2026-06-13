import Foundation
import XCTest

final class ModelBackendRedesignTests: XCTestCase {
    func testModelPaneUsesProviderTestCompatibilityPlaygroundAndAdvancedBlocks() throws {
        let source = try modelSource()

        for requiredText in [
            "Section(\"Active backend\")",
            "Section(\"Provider\")",
            "RemoteConsentSectionView(",
            "Section(\"Connection and runtime test\")",
            "Section(\"Compatibility recommendation\")",
            "Section(\"Playground\")",
            "Section(\"Local model\")",
            "Section(\"Recommended local models\")",
            "Section(\"Advanced\")",
            "Setup status",
            "Button(\"Import GGUF\")",
            "TextField(\"Search catalog\"",
            "Button(\"Clean Partial Downloads\")",
            "Button(\"Remove Selected Model\", role: .destructive)",
            "Current saved provider and routing state.",
            "Choose one provider. Only settings needed by the selected path appear here.",
            "Matrix guidance for request mode, multiple completions, and expected latency.",
            "Test the draft provider without changing the saved backend."
        ] {
            XCTAssertTrue(source.contains(requiredText), "Missing Model block contract: \(requiredText)")
        }
    }

    func testProviderFieldsAreConditionalByBackendAndFallback() throws {
        let source = try modelSource()

        XCTAssertTrue(source.contains("switch draft.engineKind"))
        XCTAssertTrue(source.contains("case .remote:"))
        XCTAssertTrue(source.contains("case .localLlama:"))
        XCTAssertTrue(source.contains("case .appleIntelligence:"))
        XCTAssertTrue(source.contains("private var remoteProviderFields"))
        XCTAssertTrue(source.contains("if draft.fallbackToRemoteOnLocalFailure"))
        XCTAssertTrue(source.contains("if draft.fallbackToRemoteOnAppleIntelligenceFailure"))
        XCTAssertTrue(source.contains("DisclosureGroup(\"Remote fallback provider\")"))
        XCTAssertTrue(source.contains("if draft.engineKind == .localLlama"))
        XCTAssertFalse(source.contains("Section(\"Remote backend settings\")"))
    }

    func testTechnicalConnectionAndPlaygroundOutputStayBehindDisclosure() throws {
        let source = try modelSource()

        XCTAssertTrue(source.contains("DisclosureGroup(\"Response details\")"))
        XCTAssertTrue(source.contains("DisclosureGroup(\"Technical error\")"))
        XCTAssertTrue(source.contains("DisclosureGroup(\"Request preview\")"))
        XCTAssertTrue(source.contains("DisclosureGroup(\"Output details\")"))
        XCTAssertTrue(source.contains("Review the technical error before changing provider settings."))
    }

    func testAdvancedActionsUseDangerZoneAndConfirmation() throws {
        let source = try modelSource()

        XCTAssertTrue(source.contains("DangerZoneView("))
        XCTAssertTrue(source.contains("Button(\"Unload Local Runtime\")"))
        XCTAssertTrue(source.contains("Button(\"Reset Remote Completion Consent\", role: .destructive)"))
        XCTAssertTrue(source.contains(".confirmationDialog(\n            \"Reset Remote Completion Consent?\""))
        XCTAssertTrue(source.contains("Button(\"Export Debug Logs...\""))
        XCTAssertTrue(source.contains("Button(\"Open Developer Diagnostics\")"))
    }

    func testModelDebugLogExportUsesSharedControllerFlow() throws {
        let source = try modelSource()
        let appControllerSource = try sourceFile("Sources/AutoCompApp/App/AppController.swift")
        let exportRange = try XCTUnwrap(source.range(of: "private func exportDebugLogs()"))
        let nextMemberRange = try XCTUnwrap(source.range(of: "\n    private var localMaxRAMBinding", range: exportRange.upperBound..<source.endIndex))
        let exportBody = String(source[exportRange.lowerBound..<nextMemberRange.lowerBound])

        XCTAssertTrue(appControllerSource.contains("enum DebugLogExportResult"))
        XCTAssertTrue(appControllerSource.contains("func exportDebugLogsWithDirectoryPicker() -> DebugLogExportResult"))
        XCTAssertTrue(exportBody.contains("controller.exportDebugLogsWithDirectoryPicker()"))
        XCTAssertTrue(exportBody.contains("advancedMessage = \"Debug logs exported to \\(exportURL.path).\""))
        XCTAssertFalse(exportBody.contains("NSOpenPanel"))
        XCTAssertFalse(exportBody.contains("withInteractionPipelineSuspended(reason: .settingsExport)"))
    }

    private func modelSource() throws -> String {
        try sourceFile("Sources/AutoCompApp/Views/Settings/Sections/ModelSettingsView.swift")
    }

}
