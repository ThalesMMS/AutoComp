import AutoCompCore
import XCTest

final class PrivacySettingsTests: XCTestCase {
    func testCollectionIsOffByDefault() {
        let settings = PrivacySettings()

        XCTAssertFalse(settings.allowsCollection(appBundleID: "com.apple.TextEdit", domain: nil))
    }

    func testDomainRuleOverridesAppRule() {
        let settings = PrivacySettings(
            collectionEnabled: true,
            perAppRules: ["com.google.Chrome": true],
            perDomainRules: ["example.com": false]
        )

        XCTAssertFalse(settings.allowsCollection(appBundleID: "com.google.Chrome", domain: "example.com"))
        XCTAssertTrue(settings.allowsCollection(appBundleID: "com.google.Chrome", domain: "other.example"))
    }
}
