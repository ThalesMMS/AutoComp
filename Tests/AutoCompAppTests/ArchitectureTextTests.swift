import XCTest

final class ArchitectureTextTests: XCTestCase {
    func testLockingSourcesUseFoundationNSLockWithLock() throws {
        let root = try packageRoot()

        for relativePath in [
            "Sources/AutoCompApp/Services/AsyncTimeout.swift",
            "Sources/AutoCompApp/Services/InputSourceMonitor.swift",
            "Sources/AutoCompApp/Services/InteractionPipelineSuspensionController.swift",
            "Sources/AutoCompApp/Services/VisualContextCoordinator.swift",
            "Sources/AutoCompApp/Services/VisualContextPipeline.swift"
        ] {
            let source = try String(
                contentsOf: root.appendingPathComponent(relativePath),
                encoding: .utf8
            )
            XCTAssertFalse(source.contains("private extension NSLock"), relativePath)
            XCTAssertFalse(source.contains("private func withLock<T>"), relativePath)
        }
    }

    func testArchitectureDocumentMapsPipelineAndContributorEntryPoints() throws {
        let root = try packageRoot()
        let document = try String(
            contentsOf: root.appendingPathComponent("Docs/Architecture.md"),
            encoding: .utf8
        )
        let readme = try String(
            contentsOf: root.appendingPathComponent("README.md"),
            encoding: .utf8
        )

        XCTAssertTrue(readme.contains("Docs/Architecture.md"))
        XCTAssertTrue(document.contains("Support -> Models -> Services -> App -> UI"))

        for heading in [
            "## Composition Root",
            "## Context Capture",
            "## Input Events",
            "## Suggestion Pipeline",
            "## Acceptance And Session State",
            "## Overlay Tiers",
            "## Backends",
            "## Visual Context",
            "## Privacy",
            "## Testing Strategy",
            "## Where To Start"
        ] {
            XCTAssertTrue(document.contains(heading), heading)
        }

        for fileReference in [
            "AutoCompAppEnvironment.swift",
            "FocusTrackingModel.swift",
            "KeyboardShortcutService.swift",
            "SuggestionEngine.swift",
            "SuggestionAcceptanceController.swift",
            "AcceptanceService.swift",
            "OverlayService.swift",
            "CompletionProviderRouter.swift",
            "VisualContextCoordinator.swift",
            "PrivacySettings.swift",
            "SuggestionEngineAcceptanceTests",
            "./script/ui_inline_preview_smoke_test.sh"
        ] {
            XCTAssertTrue(document.contains(fileReference), fileReference)
        }

        XCTAssertTrue(document.contains("Overlay bugs:"))
        XCTAssertTrue(document.contains("Context bugs:"))
        XCTAssertTrue(document.contains("Write bugs:"))
    }

}
