import AutoCompCore
import XCTest

final class PrivacySettingsTests: XCTestCase {
    func testCollectionIsOffByDefault() {
        let settings = PrivacySettings()

        XCTAssertFalse(settings.allowsCollection(appBundleID: "com.apple.TextEdit", domain: nil))
        XCTAssertFalse(settings.clipboardContextEnabled)
        XCTAssertFalse(settings.screenContextEnabled)
        XCTAssertTrue(settings.productivityMetricsEnabled)
        XCTAssertFalse(settings.localPersonalizationEnabled)
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
        XCTAssertEqual(
            settings.collectionDecision(appBundleID: "com.google.Chrome", domain: "example.com"),
            PrivacyCollectionDecision(allowed: false, ruleSource: .domainRule)
        )
    }

    func testUnknownDomainDoesNotApplyStoredDomainPrivacyRulesAsKnown() {
        let settings = PrivacySettings(
            collectionEnabled: true,
            perAppRules: ["com.google.Chrome": true],
            perDomainRules: ["docs.google.com": false]
        )

        let decision = settings.collectionDecision(appBundleID: "com.google.Chrome", domain: nil)

        XCTAssertTrue(decision.allowed)
        XCTAssertEqual(decision.ruleSource, .appRule)
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
            productivityMetricsEnabled: false,
            localPersonalizationEnabled: true,
            personalizationStrength: 0.82,
            writingPreferences: WritingPreferences(
                enabled: true,
                rules: ["Write objectively", "Avoid emoji"]
            ),
            perAppRules: ["com.apple.TextEdit": true],
            perDomainRules: ["example.com": false]
        )

        try store.save(settings)

        XCTAssertEqual(store.load(), settings)

        let data = try XCTUnwrap(defaults.data(forKey: "privacy"))
        let persistedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(persistedObject["telemetryEnabled"])
    }

    func testStoreCachesDecodedSettingsAndUpdatesCacheOnSave() throws {
        let suiteName = "AutoCompPrivacySettings-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(ReadCountingUserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let initial = PrivacySettings(productivityMetricsEnabled: true)
        defaults.set(try JSONEncoder().encode(initial), forKey: "privacy")
        defaults.resetReadCount()
        let store = PrivacySettingsStore(defaults: defaults, key: "privacy")

        XCTAssertTrue(store.load().productivityMetricsEnabled)
        XCTAssertTrue(store.load().productivityMetricsEnabled)
        XCTAssertEqual(defaults.dataReadCount, 1)

        try store.save(PrivacySettings(productivityMetricsEnabled: false))

        XCTAssertFalse(store.load().productivityMetricsEnabled)
        XCTAssertEqual(defaults.dataReadCount, 1)
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
            localPersonalizationEnabled: true,
            writingPreferences: WritingPreferences(enabled: true, rules: ["Write objectively"]),
            perDomainRules: ["docs.google.com": false]
        ))

        try store.resetLocalPrivacyDataState()

        let loaded = store.load()
        XCTAssertTrue(loaded.collectionEnabled)
        XCTAssertTrue(loaded.clipboardContextEnabled)
        XCTAssertTrue(loaded.screenContextEnabled)
        XCTAssertTrue(loaded.productivityMetricsEnabled)
        XCTAssertFalse(loaded.localPersonalizationEnabled)
        XCTAssertFalse(loaded.writingPreferences.enabled)
        XCTAssertTrue(loaded.writingPreferences.rules.isEmpty)
        XCTAssertEqual(loaded.perDomainRules["docs.google.com"], false)
    }

    func testPersonalizationStrengthControlsPromptSampleLimit() {
        XCTAssertEqual(
            PrivacySettings(localPersonalizationEnabled: false, personalizationStrength: 1).personalizationPromptSampleLimit,
            0
        )
        XCTAssertEqual(
            PrivacySettings(localPersonalizationEnabled: true, personalizationStrength: -0.2).personalizationPromptSampleLimit,
            0
        )
        XCTAssertEqual(
            PrivacySettings(localPersonalizationEnabled: true, personalizationStrength: 0).personalizationPromptSampleLimit,
            0
        )
        XCTAssertEqual(
            PrivacySettings(localPersonalizationEnabled: true, personalizationStrength: 0.01).personalizationPromptSampleLimit,
            1
        )
        XCTAssertEqual(
            PrivacySettings(localPersonalizationEnabled: true, personalizationStrength: 0.35).personalizationPromptSampleLimit,
            2
        )
        XCTAssertEqual(
            PrivacySettings(localPersonalizationEnabled: true, personalizationStrength: 1).personalizationPromptSampleLimit,
            PersonalizationSampleRecorder.defaultPromptSampleLimit
        )
        XCTAssertEqual(
            PrivacySettings(localPersonalizationEnabled: true, personalizationStrength: 1.4).personalizationPromptSampleLimit,
            PersonalizationSampleRecorder.defaultPromptSampleLimit
        )
    }

    func testDecodingLegacySettingsDefaultsWritingPreferences() throws {
        let data = Data("""
        {
          "collectionEnabled": true,
          "clipboardContextEnabled": true,
          "screenContextEnabled": false,
          "telemetryEnabled": true,
          "personalizationStrength": 0.5,
          "perAppRules": {},
          "perDomainRules": {}
        }
        """.utf8)

        let decoded = try JSONDecoder().decode(PrivacySettings.self, from: data)

        XCTAssertTrue(decoded.collectionEnabled)
        XCTAssertTrue(decoded.clipboardContextEnabled)
        XCTAssertTrue(decoded.productivityMetricsEnabled)
        XCTAssertFalse(decoded.localPersonalizationEnabled)
        XCTAssertEqual(decoded.personalizationStrength, 0.5)
        XCTAssertEqual(decoded.writingPreferences, WritingPreferences())
        let encoded = try JSONEncoder().encode(decoded)
        let encodedObject = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        XCTAssertNil(encodedObject["telemetryEnabled"])
    }
}

private final class ReadCountingUserDefaults: UserDefaults, @unchecked Sendable {
    private var storedDataReadCount = 0

    var dataReadCount: Int {
        storedDataReadCount
    }

    override func data(forKey defaultName: String) -> Data? {
        storedDataReadCount += 1
        return super.data(forKey: defaultName)
    }

    func resetReadCount() {
        storedDataReadCount = 0
    }
}
