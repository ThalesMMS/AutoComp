@testable import AutoCompApp
import Foundation
import XCTest

final class OnboardingWindowPolicyTests: XCTestCase {
    func testOnboardingContentUsesBoundedScrollableLayout() throws {
        let source = try String(
            contentsOf: try packageRoot().appendingPathComponent("Sources/AutoCompApp/Views/OnboardingView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("ScrollView"))
        XCTAssertTrue(source.contains(".frame(minWidth: 520, idealWidth: 560, minHeight: 440, idealHeight: 560)"))
    }

    func testOnboardingWindowUsesExplicitBoundedContentSize() throws {
        let source = try String(
            contentsOf: try packageRoot().appendingPathComponent("Sources/AutoCompApp/App/AppController.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("onboardingWindowContentSize = NSSize(width: 560, height: 560)"))
        XCTAssertTrue(source.contains("onboardingWindowMinimumContentSize = NSSize(width: 520, height: 440)"))
        XCTAssertTrue(source.contains("onboardingWindowMaximumContentSize = NSSize(width: 680, height: 600)"))
        XCTAssertTrue(source.contains("maxSize: Self.onboardingWindowMaximumContentSize"))
        XCTAssertTrue(source.contains("window.contentMaxSize = maxSize"))
    }

    func testSwiftUIOnboardingSceneHasDefaultSize() throws {
        let source = try String(
            contentsOf: try packageRoot().appendingPathComponent("Sources/AutoCompApp/App/AutoCompApp.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains(".defaultSize(width: 560, height: 560)"))
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
