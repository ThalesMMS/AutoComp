@testable import AutoCompApp
import Foundation
import XCTest

final class UIFontPolicyTests: XCTestCase {
    func testUIDecisionDocumentDefinesFontPolicy() throws {
        let document = try String(
            contentsOf: try packageRoot().appendingPathComponent("Docs/UIDecisions.md"),
            encoding: .utf8
        )

        for requiredText in [
            "AutoComp does not bundle custom fonts by default",
            "Inline ghost text should use the system font",
            "size approximated from the host text field geometry",
            "system monospaced design",
            "license",
            "attribution",
            "Bundled font assets: none"
        ] {
            XCTAssertTrue(document.contains(requiredText), "Missing UI font policy text: \(requiredText)")
        }
    }

    func testInlineDebugAndPromptFontPolicyIsReflectedInSource() throws {
        let root = try packageRoot()
        let overlayStyleSource = try String(
            contentsOf: root.appendingPathComponent("Sources/AutoCompApp/Services/OverlayTextStyleResolvers.swift"),
            encoding: .utf8
        )
        let focusDebugSource = try String(
            contentsOf: root.appendingPathComponent("Sources/AutoCompApp/Services/FocusDebugOverlayController.swift"),
            encoding: .utf8
        )
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/AutoCompApp/Views/SettingsRootView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(overlayStyleSource.contains(".systemFont(ofSize: fontSize(for: context))"))
        XCTAssertFalse(overlayStyleSource.contains("NSFont(name:"))
        XCTAssertTrue(focusDebugSource.contains("design: .monospaced"))
        XCTAssertTrue(settingsSource.contains(".font(.system(.caption, design: .monospaced))"))
    }

    func testPackageDoesNotBundleFontAssets() throws {
        let root = try packageRoot()
        let fontExtensions: Set<String> = ["ttf", "otf", "woff", "woff2"]
        var fontAssetPaths: [String] = []

        let enumerator = FileManager.default.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsPackageDescendants]
        )

        while let url = enumerator?.nextObject() as? URL {
            if url.lastPathComponent == ".build" || url.lastPathComponent == "dist" {
                enumerator?.skipDescendants()
                continue
            }

            if fontExtensions.contains(url.pathExtension.lowercased()) {
                fontAssetPaths.append(url.path)
            }
        }

        XCTAssertTrue(fontAssetPaths.isEmpty, "Unexpected bundled font assets: \(fontAssetPaths)")
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
