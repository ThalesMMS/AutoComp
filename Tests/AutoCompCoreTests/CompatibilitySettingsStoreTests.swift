import AutoCompCore
import XCTest

final class CompatibilitySettingsStoreTests: XCTestCase {
    func testStoreRoundTripsModeOverrides() {
        let defaultsName = "CompatibilitySettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
        }
        let store = CompatibilitySettingsStore(defaults: defaults)

        store.setMode(.manualOnly, for: "com.example.Writer")
        store.setMode(.disabled, for: "com.example.Chat")

        XCTAssertEqual(store.loadModeOverrides()["com.example.Writer"], .manualOnly)
        XCTAssertEqual(store.loadModeOverrides()["com.example.Chat"], .disabled)
        XCTAssertEqual(store.loadOverrides()["com.example.Writer"], true)
        XCTAssertEqual(store.loadOverrides()["com.example.Chat"], false)
    }

    func testRemovingOverrideRestoresDefaultLookup() {
        let defaultsName = "CompatibilitySettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
        }
        let store = CompatibilitySettingsStore(defaults: defaults)

        store.setMode(.automatic, for: "com.example.Writer")
        store.setMode(nil, for: "com.example.Writer")

        XCTAssertNil(store.loadModeOverrides()["com.example.Writer"])
    }

    func testStoreRoundTripsDomainModeOverrides() {
        let defaultsName = "CompatibilitySettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
        }
        let store = CompatibilitySettingsStore(defaults: defaults)

        store.setMode(.manualOnly, forDomain: "https://Docs.Google.com/document/d/example")

        XCTAssertEqual(store.loadDomainModeOverrides()["docs.google.com/document/d/example"], .manualOnly)
        XCTAssertEqual(
            store.loadModeOverrides()[CompatibilityCatalog.overrideKey(forDomain: "docs.google.com/document/d/example")],
            .manualOnly
        )

        store.setMode(nil, forDomain: "docs.google.com/document/d/example")

        XCTAssertNil(store.loadDomainModeOverrides()["docs.google.com/document/d/example"])
    }

    func testLegacyBooleanOverridesMapToModes() {
        let defaultsName = "CompatibilitySettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
        }
        defaults.set([
            "com.example.Enabled": true,
            "com.example.Disabled": false
        ], forKey: "compatibilityOverrides")
        let store = CompatibilitySettingsStore(defaults: defaults)

        XCTAssertEqual(store.loadModeOverrides()["com.example.Enabled"], .automatic)
        XCTAssertEqual(store.loadModeOverrides()["com.example.Disabled"], .disabled)
    }

    func testResetOverridesClearsModeAndLegacyValues() {
        let defaultsName = "CompatibilitySettingsStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
        }
        defaults.set(["com.example.Legacy": true], forKey: "compatibilityOverrides")
        let store = CompatibilitySettingsStore(defaults: defaults)
        store.setMode(.manualOnly, for: "com.example.Writer")

        store.resetOverrides()

        XCTAssertTrue(store.loadModeOverrides().isEmpty)
        XCTAssertTrue(store.loadOverrides().isEmpty)
    }
}
