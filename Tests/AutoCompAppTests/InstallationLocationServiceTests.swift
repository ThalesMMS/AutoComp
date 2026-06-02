@testable import AutoCompApp
import XCTest

final class InstallationLocationServiceTests: XCTestCase {
    func testWarnsForAppBundleOutsideApplicationsDirectories() {
        let status = InstallationLocationService.status(
            bundleURL: URL(fileURLWithPath: "/Users/test/Downloads/AutoComp.app"),
            homeDirectory: URL(fileURLWithPath: "/Users/test", isDirectory: true)
        )

        XCTAssertTrue(status.shouldWarn)
        XCTAssertEqual(status.recommendedDirectoryPath, "/Applications")
        XCTAssertEqual(status.currentDirectoryPath, "/Users/test/Downloads")
    }

    func testDoesNotWarnForSystemApplicationsInstall() {
        let status = InstallationLocationService.status(
            bundleURL: URL(fileURLWithPath: "/Applications/AutoComp.app"),
            homeDirectory: URL(fileURLWithPath: "/Users/test", isDirectory: true)
        )

        XCTAssertFalse(status.shouldWarn)
    }

    func testDoesNotWarnForUserApplicationsInstall() {
        let status = InstallationLocationService.status(
            bundleURL: URL(fileURLWithPath: "/Users/test/Applications/AutoComp.app"),
            homeDirectory: URL(fileURLWithPath: "/Users/test", isDirectory: true)
        )

        XCTAssertFalse(status.shouldWarn)
    }

    func testWarnsWhenRunningAsSwiftPMExecutable() {
        let status = InstallationLocationService.status(
            bundleURL: URL(fileURLWithPath: "/Users/test/GitHub/AutoComp/.build/debug/AutoComp"),
            homeDirectory: URL(fileURLWithPath: "/Users/test", isDirectory: true)
        )

        XCTAssertTrue(status.shouldWarn)
        XCTAssertEqual(status.currentDirectoryPath, "/Users/test/GitHub/AutoComp/.build/debug")
        XCTAssertEqual(status.revealPath, "/Users/test/GitHub/AutoComp/.build/debug/AutoComp")
    }

    func testRevealTargetUsesExecutableWhenBundleURLIsDebugDirectory() {
        let status = InstallationLocationService.status(
            bundleURL: URL(fileURLWithPath: "/Users/test/GitHub/AutoComp/.build/debug", isDirectory: true),
            executablePath: "/Users/test/GitHub/AutoComp/.build/debug/AutoComp",
            homeDirectory: URL(fileURLWithPath: "/Users/test", isDirectory: true)
        )

        XCTAssertTrue(status.shouldWarn)
        XCTAssertEqual(status.currentPath, "/Users/test/GitHub/AutoComp/.build/debug/AutoComp")
        XCTAssertEqual(status.currentDirectoryPath, "/Users/test/GitHub/AutoComp/.build/debug")
        XCTAssertEqual(status.revealPath, "/Users/test/GitHub/AutoComp/.build/debug/AutoComp")
    }

    func testRevealTargetDerivesAppBundleWhenBundleURLIsInsideAppContents() {
        let status = InstallationLocationService.status(
            bundleURL: URL(fileURLWithPath: "/Users/test/GitHub/AutoComp/dist/AutoComp.app/Contents/MacOS", isDirectory: true),
            executablePath: "/Users/test/GitHub/AutoComp/dist/AutoComp.app/Contents/MacOS/AutoComp",
            homeDirectory: URL(fileURLWithPath: "/Users/test", isDirectory: true)
        )

        XCTAssertTrue(status.shouldWarn)
        XCTAssertEqual(status.currentPath, "/Users/test/GitHub/AutoComp/dist/AutoComp.app")
        XCTAssertEqual(status.currentDirectoryPath, "/Users/test/GitHub/AutoComp/dist")
        XCTAssertEqual(status.revealPath, "/Users/test/GitHub/AutoComp/dist/AutoComp.app")
    }
}
