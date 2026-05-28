@testable import AutoCompApp
import Foundation
import XCTest

final class SettingsNavigationPolicyTests: XCTestCase {
    func testSettingsSidebarIsAlwaysVisibleWithoutSystemSplitViewToggle() throws {
        let source = try String(
            contentsOf: try packageRoot().appendingPathComponent("Sources/AutoCompApp/Views/SettingsRootView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(source.contains("NavigationSplitView"))
        XCTAssertFalse(source.contains("sidebarToggle"))
        XCTAssertTrue(source.contains("HStack(spacing: 0)"))
        XCTAssertTrue(source.contains("private let sidebarWidth: CGFloat = 210"))
        XCTAssertTrue(source.contains(".frame(width: sidebarWidth)"))
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
