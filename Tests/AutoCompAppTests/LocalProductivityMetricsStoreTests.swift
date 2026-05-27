import AutoCompCore
@testable import AutoCompApp
import XCTest

@MainActor
final class LocalProductivityMetricsStoreTests: XCTestCase {
    func testAcceptedChunksCountWordsWithoutPersistingText() throws {
        let defaults = try makeDefaults()
        let privacyStore = PrivacySettingsStore(defaults: defaults, key: "privacy")
        try privacyStore.save(PrivacySettings(productivityMetricsEnabled: true))
        let store = LocalProductivityMetricsStore(
            defaults: defaults,
            key: "metrics",
            privacyStore: privacyStore,
            calendar: utcCalendar(),
            now: { Date(timeIntervalSince1970: 100) }
        )

        store.recordAcceptedText(" hello, world! cafe\u{301} 123 🚀")

        XCTAssertEqual(store.snapshot.wordsAcceptedToday, 4)
        XCTAssertEqual(store.snapshot.wordsAcceptedTotal, 4)
        XCTAssertEqual(store.snapshot.suggestionsAccepted, 1)

        let encoded = try XCTUnwrap(defaults.data(forKey: "metrics"))
        let persisted = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertFalse(persisted.contains("hello"))
        XCTAssertFalse(persisted.contains("world"))
        XCTAssertFalse(persisted.contains("cafe"))
    }

    func testDisabledMetricsDoNotRecordNewCounters() throws {
        let defaults = try makeDefaults()
        let privacyStore = PrivacySettingsStore(defaults: defaults, key: "privacy")
        try privacyStore.save(PrivacySettings(productivityMetricsEnabled: false))
        let store = LocalProductivityMetricsStore(
            defaults: defaults,
            key: "metrics",
            privacyStore: privacyStore,
            calendar: utcCalendar(),
            now: { Date(timeIntervalSince1970: 100) }
        )

        store.recordAcceptedText("blocked text")
        store.recordDismissedSuggestion()
        store.recordBackendLatency(42)

        XCTAssertFalse(store.snapshot.isEnabled)
        XCTAssertEqual(store.snapshot.wordsAcceptedTotal, 0)
        XCTAssertEqual(store.snapshot.suggestionsAccepted, 0)
        XCTAssertEqual(store.snapshot.suggestionsDismissed, 0)
        XCTAssertNil(store.snapshot.averageBackendLatencyMs)
    }

    func testTodayCounterRollsOverWithoutResettingTotal() throws {
        let defaults = try makeDefaults()
        let privacyStore = PrivacySettingsStore(defaults: defaults, key: "privacy")
        var currentDate = Date(timeIntervalSince1970: 100)
        let store = LocalProductivityMetricsStore(
            defaults: defaults,
            key: "metrics",
            privacyStore: privacyStore,
            calendar: utcCalendar(),
            now: { currentDate }
        )

        store.recordAcceptedText("first day")
        currentDate = Date(timeIntervalSince1970: 90_000)
        store.recordAcceptedText("second")

        XCTAssertEqual(store.snapshot.wordsAcceptedToday, 1)
        XCTAssertEqual(store.snapshot.wordsAcceptedTotal, 3)
    }

    func testDismissalLatencyAverageAndResetStayNumericOnly() throws {
        let defaults = try makeDefaults()
        let privacyStore = PrivacySettingsStore(defaults: defaults, key: "privacy")
        let store = LocalProductivityMetricsStore(
            defaults: defaults,
            key: "metrics",
            privacyStore: privacyStore,
            calendar: utcCalendar(),
            now: { Date(timeIntervalSince1970: 100) }
        )

        store.recordAcceptedText("one")
        store.recordDismissedSuggestion()
        store.recordDismissedSuggestion()
        store.recordBackendLatency(10)
        store.recordBackendLatency(21)

        XCTAssertEqual(store.snapshot.suggestionsDismissed, 2)
        XCTAssertEqual(store.snapshot.averageBackendLatencyMs, 16)

        store.reset()

        XCTAssertEqual(store.snapshot.wordsAcceptedTotal, 0)
        XCTAssertEqual(store.snapshot.suggestionsAccepted, 0)
        XCTAssertEqual(store.snapshot.suggestionsDismissed, 0)
        XCTAssertNil(store.snapshot.averageBackendLatencyMs)
    }

    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "AutoCompProductivityMetrics-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
