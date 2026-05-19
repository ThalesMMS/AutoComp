import AutoCompCore
import XCTest

final class CompatibilityCatalogTests: XCTestCase {
    func testCodeEditorsAreDisabledByDefault() {
        let catalog = CompatibilityCatalog()
        let decision = catalog.decision(bundleID: "com.microsoft.VSCode", domain: nil)

        XCTAssertFalse(decision.enabled)
        XCTAssertEqual(decision.mode, .disabled)
        XCTAssertEqual(decision.profile.status, .partial)
    }

    func testFirefoxUsesMirrorWindowMode() {
        let decision = CompatibilityCatalog().decision(bundleID: "org.mozilla.firefox", domain: nil)

        XCTAssertTrue(decision.enabled)
        XCTAssertEqual(decision.mode, .mirrorWindow)
        XCTAssertEqual(decision.profile.status, .mirrorOnly)
    }

    func testUnknownAppsUseInlineModeWhenPossible() {
        let decision = CompatibilityCatalog().decision(bundleID: "com.example.UnknownEditor", domain: nil)

        XCTAssertTrue(decision.enabled)
        XCTAssertEqual(decision.mode, .inline)
        XCTAssertEqual(decision.profile.status, .partial)
    }

    func testGoogleDocsRequiresSetupButSheetsAreUnsupported() {
        let catalog = CompatibilityCatalog()

        let docs = catalog.decision(bundleID: "com.google.Chrome", domain: "docs.google.com")
        XCTAssertEqual(docs.profile.status, .setupNeeded)
        XCTAssertEqual(docs.mode, .inline)
        XCTAssertNotNil(docs.setupMessage)

        let sheets = catalog.decision(bundleID: "com.google.Chrome", domain: "docs.google.com/spreadsheets")
        XCTAssertEqual(sheets.profile.status, .unsupported)
        XCTAssertEqual(sheets.mode, .disabled)
    }
}
