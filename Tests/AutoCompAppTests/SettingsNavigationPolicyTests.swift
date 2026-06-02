@testable import AutoCompApp
import Foundation
import XCTest

final class SettingsNavigationPolicyTests: XCTestCase {
    func testSettingsUsesNavigationSplitViewShellAndSemanticSidebar() throws {
        let rootSource = try String(
            contentsOf: try packageRoot().appendingPathComponent("Sources/AutoCompApp/Views/SettingsRootView.swift"),
            encoding: .utf8
        )
        let shellSource = try String(
            contentsOf: try packageRoot().appendingPathComponent("Sources/AutoCompApp/Views/Settings/SettingsNavigationShell.swift"),
            encoding: .utf8
        )
        let sidebarSource = try String(
            contentsOf: try packageRoot().appendingPathComponent("Sources/AutoCompApp/Views/Settings/SettingsSidebarView.swift"),
            encoding: .utf8
        )
        let rowSource = try String(
            contentsOf: try packageRoot().appendingPathComponent("Sources/AutoCompApp/Views/Settings/Components/SettingsSidebarRow.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(rootSource.contains("SettingsNavigationShell(selection: $controller.selectedSettingsSection)"))
        XCTAssertFalse(rootSource.contains("HStack(spacing: 0)"))
        XCTAssertFalse(rootSource.contains("PermissionSettingsView"))
        XCTAssertFalse(rootSource.contains("AppCompatibilitySettingsView"))
        XCTAssertFalse(rootSource.contains("PrivacySettingsView"))
        XCTAssertFalse(rootSource.contains("ShortcutSettingsView"))
        XCTAssertFalse(rootSource.contains("ModelSettingsView"))
        XCTAssertTrue(shellSource.contains("NavigationSplitView(columnVisibility: $columnVisibility)"))
        XCTAssertTrue(shellSource.contains("SettingsSidebarView(selection: $selection)"))
        XCTAssertTrue(shellSource.contains("navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)"))
        XCTAssertTrue(shellSource.contains("SettingsSidebarToolbarSuppressor"))
        XCTAssertTrue(shellSource.contains(".toggleSidebar"))
        XCTAssertTrue(shellSource.contains(".sidebarTrackingSeparator"))
        XCTAssertTrue(sidebarSource.contains("ForEach(SettingsSection.allCases)"))
        XCTAssertTrue(rowSource.contains("section.systemImage"))
        XCTAssertTrue(rowSource.contains("section.accentColor"))
        XCTAssertTrue(rowSource.contains("section.sidebarDescription"))
    }

    func testSettingsSectionOrderAndSidebarMetadata() {
        XCTAssertEqual(
            SettingsSection.allCases,
            [.general, .setup, .model, .shortcuts, .privacy, .apps, .health, .statistics, .developer]
        )

        for section in SettingsSection.allCases {
            XCTAssertFalse(section.title.isEmpty)
            XCTAssertFalse(section.systemImage.isEmpty)
            XCTAssertFalse(section.sidebarDescription.isEmpty)
        }
    }

    func testSettingsPanesUseSharedFormComponent() throws {
        let settingsSource = try settingsSourceContents(packageRoot: packageRoot())
        let useCount = settingsSource.components(separatedBy: "SettingsPaneForm(title:").count - 1

        XCTAssertGreaterThanOrEqual(useCount, 3)
        XCTAssertTrue(settingsSource.contains("struct SettingsPaneForm<Content: View>: View"))
    }

    func testSettingsTaxonomySeparatesCommonSetupStatisticsAndDeveloperSurfaces() throws {
        let settingsSource = try settingsSourceContents(packageRoot: packageRoot())

        XCTAssertTrue(settingsSource.contains("struct GeneralSettingsView: View"))
        XCTAssertTrue(settingsSource.contains("struct SetupSettingsView: View"))
        XCTAssertTrue(settingsSource.contains("struct StatisticsSettingsView: View"))
        XCTAssertTrue(settingsSource.contains("struct DeveloperSettingsView: View"))
        XCTAssertTrue(settingsSource.contains("Section(\"Emoji picker\")"))
        XCTAssertTrue(settingsSource.contains("EmojiVariantPreferences"))
        XCTAssertTrue(settingsSource.contains("controller.emojiPickerAcceptKeyLabel"))
        XCTAssertTrue(settingsSource.contains("Section(\"Local metrics\")"))
        XCTAssertTrue(settingsSource.contains("Section(\"Debug\")"))
        XCTAssertTrue(settingsSource.contains("OverlayRecoveryRecommendationView"))
        XCTAssertFalse(settingsSource.contains("case permissions = \"Permissions\""))
    }

    func testSettingsWindowHasMinimumSize() throws {
        let source = try String(
            contentsOf: try packageRoot().appendingPathComponent("Sources/AutoCompApp/App/AppController.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("settingsWindowMinimumContentSize = NSSize(width: 880, height: 560)"))
        XCTAssertTrue(source.contains("let settingsWindowSize = Self.settingsWindowMinimumContentSize"))
        XCTAssertTrue(source.contains("minSize: settingsWindowSize"))
        XCTAssertTrue(source.contains("window.minSize = minSize"))
        XCTAssertTrue(source.contains("window.contentMinSize = minSize"))
        XCTAssertTrue(source.contains("MinimumContentSizeWindowDelegate"))
        XCTAssertTrue(source.contains("window.delegate = settingsWindowResizeDelegate"))
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
