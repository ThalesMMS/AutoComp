@testable import AutoCompApp
import XCTest

final class AppBundleLocatorTests: XCTestCase {
    func testExecutablePathResolutionIgnoresBlankAndUnknownSentinels() {
        XCTAssertNil(AppBundleLocator.bundleURL(containingExecutablePath: ""))
        XCTAssertNil(AppBundleLocator.bundleURL(containingExecutablePath: "   \n"))
        XCTAssertNil(AppBundleLocator.bundleURL(containingExecutablePath: "unknown"))
    }

    func testExecutablePathResolutionWalksUpToContainingAppBundle() {
        let bundleURL = AppBundleLocator.bundleURL(
            containingExecutablePath: "/Users/test/GitHub/AutoComp/dist/AutoComp.app/Contents/MacOS/AutoComp"
        )

        XCTAssertEqual(bundleURL?.path, "/Users/test/GitHub/AutoComp/dist/AutoComp.app")
    }

    func testDirectoryNearPathUsesExecutableDirectoryAndRejectsUnknown() {
        XCTAssertNil(AppBundleLocator.directoryURL(nearPath: "unknown"))

        let directoryURL = AppBundleLocator.directoryURL(
            nearPath: "/Users/test/GitHub/AutoComp/.build/debug/AutoComp"
        )

        XCTAssertEqual(directoryURL?.path, "/Users/test/GitHub/AutoComp/.build/debug")
    }
}
