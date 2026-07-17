@testable import AutoCompApp
import AutoCompCore
import XCTest

final class BrowserContextResolverTests: XCTestCase {
    func testResolutionCacheUsesTTLAndExplicitInvalidation() {
        var now = Date(timeIntervalSince1970: 1_000)
        var executionCount = 0
        var nextURL = "https://first.example/path"
        let resolver = BrowserContextResolver(
            scriptRunner: { _ in
                executionCount += 1
                return .success(nextURL)
            },
            cacheTTL: 1,
            now: { now }
        )

        XCTAssertEqual(resolver.activeDomain(for: "com.google.Chrome"), "first.example")
        nextURL = "https://second.example/path"
        XCTAssertEqual(resolver.activeDomain(for: "com.google.Chrome"), "first.example")
        XCTAssertEqual(executionCount, 1)

        now.addTimeInterval(1.1)
        XCTAssertEqual(resolver.activeDomain(for: "com.google.Chrome"), "second.example")
        resolver.invalidate(bundleID: "com.google.Chrome")
        XCTAssertEqual(resolver.activeDomain(for: "com.google.Chrome"), "second.example")
        XCTAssertEqual(executionCount, 3)
        XCTAssertEqual(
            resolver.diagnostics,
            BrowserContextResolverDiagnostics(cacheHits: 1, scriptExecutions: 3)
        )
    }

    func testCompiledRunnerCompilesSourceOnceAcrossExecutions() {
        var compilationCount = 0
        var executionCount = 0
        let runner = CompiledBrowserScriptRunner { _ in
            compilationCount += 1
            return {
                executionCount += 1
                return .success("https://example.com")
            }
        }

        XCTAssertEqual(runner.run("script"), .success("https://example.com"))
        XCTAssertEqual(runner.run("script"), .success("https://example.com"))
        XCTAssertEqual(compilationCount, 1)
        XCTAssertEqual(executionCount, 2)
    }

    func testKnownBrowserDomainNormalizesWorkspacePathsWithoutFullURL() {
        for (url, expectedDomain) in [
            ("https://docs.google.com/spreadsheets/d/private-sheet?gid=0", "docs.google.com/spreadsheets"),
            ("https://docs.google.com/presentation/d/private-deck#slide=id.p", "docs.google.com/presentation")
        ] {
            let resolver = BrowserContextResolver { script in
                XCTAssertTrue(script.contains("Google Chrome"))
                return .success(url)
            }

            let resolution = resolver.activeDomainResolution(for: "com.google.Chrome")

            XCTAssertEqual(resolution.status, .known)
            XCTAssertEqual(resolution.domain, expectedDomain)
            XCTAssertEqual(resolution.diagnosticValue, expectedDomain)
            XCTAssertFalse(resolution.diagnosticValue.contains("private"), url)
        }
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
