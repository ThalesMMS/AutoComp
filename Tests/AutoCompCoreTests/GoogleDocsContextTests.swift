import AutoCompCore
import XCTest

final class GoogleDocsContextTests: XCTestCase {
    func testClassifiesDocsSheetsAndSlidesDomains() {
        XCTAssertEqual(
            GoogleDocsContext.match(
                bundleID: "com.google.Chrome",
                domain: "https://docs.google.com/document/d/example?tab=t.0",
                appGate: .chrome
            )?.surface,
            .document
        )
        XCTAssertEqual(
            GoogleDocsContext.surface(for: "docs.google.com/spreadsheets/d/example"),
            .spreadsheet
        )
        XCTAssertEqual(
            GoogleDocsContext.surface(for: "https://docs.google.com/presentation/d/example#slide=id.p"),
            .presentation
        )
        XCTAssertEqual(
            GoogleDocsContext.surface(for: "https://docs.google.com/forms/d/example"),
            .other
        )
    }

    func testDefaultMatcherOnlyAllowsDocsDocumentsOnExactDocsHost() {
        XCTAssertTrue(
            GoogleDocsContext.matches(
                bundleID: "com.google.Chrome",
                domain: "docs.google.com/document/d/example",
                appGate: .chrome
            )
        )
        XCTAssertFalse(
            GoogleDocsContext.matches(
                bundleID: "com.google.Chrome",
                domain: "docs.google.com/spreadsheets/d/example",
                appGate: .chrome
            )
        )
        XCTAssertFalse(
            GoogleDocsContext.matches(
                bundleID: "com.google.Chrome",
                domain: "docs.google.com.evil.test/document/d/example",
                appGate: .chrome
            )
        )
    }

    func testAppGateMakesHostEligibilityExplicit() {
        XCTAssertTrue(
            GoogleDocsContext.matches(
                bundleID: "com.apple.Safari",
                domain: "docs.google.com",
                appGate: .browser
            )
        )
        XCTAssertFalse(
            GoogleDocsContext.matches(
                bundleID: "com.openai.codex",
                domain: "docs.google.com",
                appGate: .browser
            )
        )
        XCTAssertTrue(
            GoogleDocsContext.matches(
                bundleID: "com.openai.codex",
                domain: "docs.google.com",
                appGate: .webLike
            )
        )
        XCTAssertFalse(
            GoogleDocsContext.matches(
                bundleID: "com.apple.Safari",
                domain: "docs.google.com",
                appGate: .chrome
            )
        )
    }

    func testWorkspaceSurfacesCanBeAllowedExplicitly() {
        XCTAssertTrue(
            GoogleDocsContext.matches(
                bundleID: "com.google.Chrome",
                domain: "https://docs.google.com/spreadsheets/d/example",
                allowedSurfaces: [.spreadsheet, .presentation]
            )
        )
        XCTAssertTrue(
            GoogleDocsContext.matches(
                bundleID: "com.google.Chrome",
                domain: "https://docs.google.com/presentation/d/example",
                allowedSurfaces: [.spreadsheet, .presentation]
            )
        )
        XCTAssertFalse(
            GoogleDocsContext.matches(
                bundleID: "com.google.Chrome",
                domain: "https://docs.google.com/document/d/example",
                allowedSurfaces: [.spreadsheet, .presentation]
            )
        )
    }
}
