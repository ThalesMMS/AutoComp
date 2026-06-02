import Foundation
import XCTest

final class AppCompatibilityPaneRedesignTests: XCTestCase {
    func testAppsPaneHasFocusedAppSearchDomainRulesAndAdvancedResetSections() throws {
        let source = try appsSource()

        for requiredText in [
            "SettingsPaneForm(title: \"Apps\")",
            "Section(\"Focused app\")",
            "Section(\"Installed apps\")",
            "Section(\"Domain rules\")",
            "Section(\"Advanced\")",
            "Focus a text field to inspect app compatibility.",
            "Search by app name or bundle ID. Scans installed application folders, not only running apps.",
            "Domain rules are separate from bundle ID overrides",
            "Reset Compatibility Overrides?"
        ] {
            XCTAssertTrue(source.contains(requiredText), "Missing Apps pane contract: \(requiredText)")
        }
    }

    func testFocusedAppCardUsesLiveFocusSnapshotAndQuickActions() throws {
        let source = try appsSource()

        XCTAssertTrue(source.contains("@ObservedObject var focusTrackingModel: FocusTrackingModel"))
        XCTAssertTrue(source.contains("if let snapshot = focusTrackingModel.snapshot"))
        XCTAssertTrue(source.contains("LabeledContent(\"Bundle ID\""))
        XCTAssertTrue(source.contains("LabeledContent(\"Rule source\""))
        XCTAssertTrue(source.contains("LabeledContent(\"Effective mode\""))
        XCTAssertTrue(source.contains("CompatibilityModePicker(\n                    title: \"App mode\""))
        XCTAssertTrue(source.contains("CompatibilityModePicker(\n                        title: \"Domain mode\""))
        XCTAssertTrue(source.contains("Button(\"Find in List\")"))
        XCTAssertTrue(source.contains("Button(\"Reset App Override\")"))
        XCTAssertTrue(source.contains("Button(\"Reset Domain Rule\")"))
    }

    func testInstalledAppsShowIconsOverrideSourceAndModePicker() throws {
        let source = try appsSource()

        XCTAssertTrue(source.contains("InstalledApplicationFilter.filter(installedApps, matching: searchText)"))
        XCTAssertTrue(source.contains("Image(nsImage: app.icon)"))
        XCTAssertTrue(source.contains("CompatibilityPresentation.sourceTitle(for: decision.ruleSource)"))
        XCTAssertTrue(source.contains("Text(\"Default/catalog\").tag(CompatibilityOverrideMode?.none)"))
        XCTAssertTrue(source.contains("setMode(mode, for: bundleID)"))
        XCTAssertTrue(source.contains("controller.compatibilitySettings.setMode(mode, for: bundleID)"))
    }

    func testDomainRulesStaySeparateFromBundleOverrides() throws {
        let source = try appsSource()

        XCTAssertTrue(source.contains("key.hasPrefix(\"domain:\")"))
        XCTAssertTrue(source.contains("CompatibilityCatalog.overrideKey(forDomain: normalizedDomain)"))
        XCTAssertTrue(source.contains("controller.compatibilitySettings.setMode(mode, forDomain: normalizedDomain)"))
        XCTAssertTrue(source.contains("StatusBadge(\"Domain rule\""))
        XCTAssertTrue(source.contains("Button(\"Reset All Compatibility Overrides\", role: .destructive)"))
        XCTAssertTrue(source.contains("controller.compatibilitySettings.resetOverrides()"))
    }

    private func appsSource() throws -> String {
        try String(
            contentsOf: try packageRoot().appendingPathComponent("Sources/AutoCompApp/Views/Settings/Sections/AppsSettingsView.swift"),
            encoding: .utf8
        )
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
