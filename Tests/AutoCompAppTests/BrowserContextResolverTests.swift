@testable import AutoCompApp
import AutoCompCore
import XCTest

final class BrowserContextResolverTests: XCTestCase {
    func testKnownBrowserDomainNormalizesWorkspacePathsWithoutFullURL() {
        let resolver = BrowserContextResolver { script in
            XCTAssertTrue(script.contains("Google Chrome"))
            return .success("https://docs.google.com/spreadsheets/d/private-sheet?gid=0")
        }

        let resolution = resolver.activeDomainResolution(for: "com.google.Chrome")

        XCTAssertEqual(resolution.status, .known)
        XCTAssertEqual(resolution.domain, "docs.google.com/spreadsheets")
        XCTAssertEqual(resolution.diagnosticValue, "docs.google.com/spreadsheets")
        XCTAssertFalse(resolution.diagnosticValue.contains("private-sheet"))
    }

    func testAppleEventsDeniedReportsStructuredStateAndLeavesAutocompleteAppEligible() {
        let resolver = BrowserContextResolver { _ in
            .failure(code: -1743, message: "Not authorized to send Apple events.")
        }

        let resolution = resolver.activeDomainResolution(for: "com.apple.Safari")
        let compatibility = CompatibilityCatalog().decision(
            bundleID: "com.apple.Safari",
            domain: resolution.domain
        )

        XCTAssertEqual(resolution.status, .unavailableAppleEventsDenied)
        XCTAssertNil(resolution.domain)
        XCTAssertEqual(resolution.diagnosticValue, "unavailable-appleevents-denied")
        XCTAssertTrue(compatibility.enabled)
        XCTAssertTrue(compatibility.allowsAutomaticSuggestions)
        XCTAssertEqual(compatibility.ruleSource, .default)
    }

    func testBrowserScriptFailuresAreModeledForSupportedBrowsers() {
        for bundleID in [
            "com.apple.Safari",
            "com.google.Chrome",
            "com.brave.Browser",
            "com.microsoft.edgemac"
        ] {
            let resolver = BrowserContextResolver { _ in
                .failure(code: -2700, message: "script failed")
            }

            let resolution = resolver.activeDomainResolution(for: bundleID)

            XCTAssertEqual(resolution.status, .unavailableBrowserScriptFailed, bundleID)
            XCTAssertNil(resolution.domain, bundleID)
            XCTAssertEqual(resolution.diagnosticValue, "unavailable-browser-script-failed", bundleID)
        }
    }

    func testNonBrowserAppsReportNotBrowserWithoutRunningScript() {
        var didRunScript = false
        let resolver = BrowserContextResolver { _ in
            didRunScript = true
            return .success("https://example.com")
        }

        let resolution = resolver.activeDomainResolution(for: "com.apple.TextEdit")

        XCTAssertEqual(resolution.status, .notBrowser)
        XCTAssertNil(resolution.domain)
        XCTAssertEqual(resolution.diagnosticValue, "not-browser")
        XCTAssertFalse(didRunScript)
    }
}
