@testable import AutoCompApp
import Foundation
import XCTest

final class ShortcutRecordingDecisionTests: XCTestCase {
    func testDecisionDocumentChoosesInternalRecorderAndCoversAcceptanceScope() throws {
        let root = try packageRoot()
        let document = try String(
            contentsOf: root.appendingPathComponent("Docs/ShortcutRecordingDecision.md"),
            encoding: .utf8
        )

        for requiredText in [
            "AutoComp uses its own SwiftUI/AppKit shortcut recorder",
            "instead of adding MASShortcut",
            "NSViewRepresentable",
            "Input Monitoring",
            "System Shortcut Conflicts",
            "keyCode",
            "modifiers",
            "trigger",
            "Contextual Tab acceptance must stay in the existing event-tap pipeline"
        ] {
            XCTAssertTrue(document.contains(requiredText), "Missing shortcut decision text: \(requiredText)")
        }
    }

    func testSettingsUsesInternalRecorderAndPackageDoesNotAddMASShortcut() throws {
        let root = try packageRoot()
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/AutoCompApp/Views/SettingsRootView.swift"),
            encoding: .utf8
        )
        let package = try String(
            contentsOf: root.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(settingsSource.contains("ShortcutRecorderButton"))
        XCTAssertTrue(settingsSource.contains("ShortcutCaptureView: NSViewRepresentable"))
        XCTAssertTrue(settingsSource.contains("KeyboardShortcutBinding(event: event, trigger: .keyDown)"))
        XCTAssertTrue(settingsSource.contains("KeyboardShortcutBinding(event: event, trigger: .flagsChanged)"))
        XCTAssertFalse(package.contains("MASShortcut"))
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
