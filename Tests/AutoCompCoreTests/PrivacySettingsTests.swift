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

    func testStoreRoundTripsAllPrivacyControlsAndRules() throws {
        let suiteName = "AutoCompPrivacySettings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = PrivacySettingsStore(defaults: defaults, key: "privacy")
        let settings = PrivacySettings(
            collectionEnabled: true,
            clipboardContextEnabled: true,
            screenContextEnabled: true,
            personalizationStrength: 0.82,
            perAppRules: ["com.apple.TextEdit": true],
            perDomainRules: ["example.com": false]
        )

        try store.save(settings)

        XCTAssertEqual(store.load(), settings)
    }
}
