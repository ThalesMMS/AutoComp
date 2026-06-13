import AutoCompCore
import XCTest

final class WebHostAppsTests: XCTestCase {
    func testClassifiesBrowsersAndHostedWebSurfacesSeparately() {
        for bundleID in [
            "com.apple.Safari",
            "com.google.Chrome",
            "com.brave.Browser",
            "com.microsoft.edgemac",
            "company.thebrowser.Browser",
            "company.thebrowser.dia"
        ] {
            XCTAssertTrue(WebHostApps.isBrowser(bundleID), bundleID)
            XCTAssertTrue(WebHostApps.isWebLike(bundleID), bundleID)
            XCTAssertFalse(WebHostApps.isAppHostedWebSurface(bundleID), bundleID)
        }

        for bundleID in [
            "com.openai.codex",
            "com.todesktop.230313mzl4w4u92"
        ] {
            XCTAssertFalse(WebHostApps.isBrowser(bundleID), bundleID)
            XCTAssertTrue(WebHostApps.isWebLike(bundleID), bundleID)
            XCTAssertTrue(WebHostApps.isAppHostedWebSurface(bundleID), bundleID)
        }

        XCTAssertFalse(WebHostApps.isBrowser("com.apple.TextEdit"))
        XCTAssertFalse(WebHostApps.isWebLike("com.apple.TextEdit"))
        XCTAssertFalse(WebHostApps.isAppHostedWebSurface("com.apple.TextEdit"))
    }
}
