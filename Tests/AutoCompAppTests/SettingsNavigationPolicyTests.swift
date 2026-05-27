@testable import AutoCompApp
import Foundation
import XCTest

final class SettingsNavigationPolicyTests: XCTestCase {
    func testSettingsSidebarIsAlwaysVisibleAndDoesNotExposeDrawerToggle() throws {
        let source = try String(
            contentsOf: try packageRoot().appendingPathComponent("Sources/AutoCompApp/Views/SettingsRootView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("NavigationSplitView(columnVisibility: .constant(.all))"))
        XCTAssertTrue(source.contains(".toolbar(removing: .sidebarToggle)"))
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
