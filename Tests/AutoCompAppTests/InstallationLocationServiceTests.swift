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

    func testDoesNotWarnWhenRunningAsSwiftPMExecutable() {
        let status = InstallationLocationService.status(
            bundleURL: URL(fileURLWithPath: "/Users/test/GitHub/AutoComp/.build/debug/AutoComp"),
            homeDirectory: URL(fileURLWithPath: "/Users/test", isDirectory: true)
        )

        XCTAssertFalse(status.shouldWarn)
    }
}
