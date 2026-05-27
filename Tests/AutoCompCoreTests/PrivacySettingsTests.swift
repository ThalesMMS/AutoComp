import AutoCompCore
import XCTest

final class PrivacySettingsTests: XCTestCase {
    func testCollectionIsOffByDefault() {
        let settings = PrivacySettings()

        XCTAssertFalse(settings.allowsCollection(appBundleID: "com.apple.TextEdit", domain: nil))
        XCTAssertFalse(settings.clipboardContextEnabled)
        XCTAssertFalse(settings.screenContextEnabled)
        XCTAssertFalse(settings.telemetryEnabled)
        XCTAssertTrue(settings.productivityMetricsEnabled)
        XCTAssertFalse(settings.writingPreferences.enabled)
        XCTAssertTrue(settings.writingPreferences.rules.isEmpty)
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

    func testBrowserDomainRulesNormalizeAndUseMostSpecificMatch() {
        let settings = PrivacySettings(
            collectionEnabled: true,
            perAppRules: ["com.google.Chrome": true],
            perDomainRules: [
                "docs.google.com": false,
                "docs.google.com/spreadsheets": true
            ]
        )

        XCTAssertFalse(settings.allowsCollection(
            appBundleID: "com.google.Chrome",
            domain: "https://docs.google.com/document/d/example?tab=t.0"
        ))
        XCTAssertTrue(settings.allowsCollection(
            appBundleID: "com.google.Chrome",
            domain: "docs.google.com/spreadsheets/d/example"
        ))
        XCTAssertTrue(settings.allowsCollection(
            appBundleID: "com.google.Chrome",
            domain: "mail.google.com"
        ))
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
            telemetryEnabled: true,
            productivityMetricsEnabled: false,
            personalizationStrength: 0.82,
            writingPreferences: WritingPreferences(
                enabled: true,
                rules: ["Write objectively", "Avoid emoji"]
            ),
            perAppRules: ["com.apple.TextEdit": true],
            perDomainRules: ["example.com": false]
        )

        try store.save(settings)

        var expectedSettings = settings
        expectedSettings.telemetryEnabled = false
        XCTAssertEqual(store.load(), expectedSettings)

        let data = try XCTUnwrap(defaults.data(forKey: "privacy"))
        let persistedSettings = try JSONDecoder().decode(PrivacySettings.self, from: data)
        XCTAssertFalse(persistedSettings.telemetryEnabled)
    }

    func testStoreResetsWritingPreferencesForPrivacyDeleteAll() throws {
        let suiteName = "AutoCompPrivacySettings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = PrivacySettingsStore(defaults: defaults, key: "privacy")
        try store.save(PrivacySettings(
            clipboardContextEnabled: true,
            writingPreferences: WritingPreferences(enabled: true, rules: ["Write objectively"])
        ))

        try store.resetWritingPreferences()

        let loaded = store.load()
        XCTAssertTrue(loaded.clipboardContextEnabled)
        XCTAssertFalse(loaded.writingPreferences.enabled)
        XCTAssertTrue(loaded.writingPreferences.rules.isEmpty)
    }

    func testStoreResetsLocalPrivacyDataStateWithoutChangingCollectionRules() throws {
        let suiteName = "AutoCompPrivacySettings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = PrivacySettingsStore(defaults: defaults, key: "privacy")
        try store.save(PrivacySettings(
            collectionEnabled: true,
            clipboardContextEnabled: true,
            screenContextEnabled: true,
            telemetryEnabled: true,
            writingPreferences: WritingPreferences(enabled: true, rules: ["Write objectively"]),
            perDomainRules: ["docs.google.com": false]
        ))

        try store.resetLocalPrivacyDataState()

        let loaded = store.load()
        XCTAssertTrue(loaded.collectionEnabled)
        XCTAssertTrue(loaded.clipboardContextEnabled)
        XCTAssertTrue(loaded.screenContextEnabled)
        XCTAssertFalse(loaded.telemetryEnabled)
        XCTAssertTrue(loaded.productivityMetricsEnabled)
        XCTAssertFalse(loaded.writingPreferences.enabled)
        XCTAssertTrue(loaded.writingPreferences.rules.isEmpty)
        XCTAssertEqual(loaded.perDomainRules["docs.google.com"], false)
    }

    func testDecodingLegacySettingsDefaultsWritingPreferences() throws {
        let data = Data("""
        {
          "collectionEnabled": true,
          "clipboardContextEnabled": true,
          "screenContextEnabled": false,
          "personalizationStrength": 0.5,
          "perAppRules": {},
          "perDomainRules": {}
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(PrivacySettings.self, from: data)

        XCTAssertTrue(decoded.collectionEnabled)
        XCTAssertTrue(decoded.clipboardContextEnabled)
        XCTAssertFalse(decoded.telemetryEnabled)
        XCTAssertTrue(decoded.productivityMetricsEnabled)
        XCTAssertEqual(decoded.personalizationStrength, 0.5)
        XCTAssertEqual(decoded.writingPreferences, WritingPreferences())
    }
}
