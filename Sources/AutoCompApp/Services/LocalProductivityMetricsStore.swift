import AutoCompCore
import Combine
import Foundation

struct ProductivityMetricsSnapshot: Equatable {
    let isEnabled: Bool
    let dayKey: String
    let wordsAcceptedToday: Int
    let wordsAcceptedTotal: Int
    let suggestionsAccepted: Int
    let suggestionsDismissed: Int
    let latencySampleCount: Int
    let averageBackendLatencyMs: Int?
    let lastLatencyReport: CompletionLatencyReport?

    init(
        isEnabled: Bool,
        dayKey: String,
        wordsAcceptedToday: Int,
        wordsAcceptedTotal: Int,
        suggestionsAccepted: Int,
        suggestionsDismissed: Int,
        latencySampleCount: Int,
        averageBackendLatencyMs: Int?,
        lastLatencyReport: CompletionLatencyReport? = nil
    ) {
        self.isEnabled = isEnabled
        self.dayKey = dayKey
        self.wordsAcceptedToday = wordsAcceptedToday
        self.wordsAcceptedTotal = wordsAcceptedTotal
        self.suggestionsAccepted = suggestionsAccepted
        self.suggestionsDismissed = suggestionsDismissed
        self.latencySampleCount = latencySampleCount
        self.averageBackendLatencyMs = averageBackendLatencyMs
        self.lastLatencyReport = lastLatencyReport
    }

    var menuValue: String {
        guard isEnabled else {
            return "Off"
        }
        return "\(wordsAcceptedToday) words today"
    }

    var menuAction: String {
        guard isEnabled else {
            return "Local productivity counters are disabled in Privacy."
        }

        let latency = averageBackendLatencyMs.map { "\($0) ms average" } ?? "no latency samples"
        return "\(wordsAcceptedTotal) total words, \(suggestionsAccepted) accepted, \(suggestionsDismissed) dismissed, \(latency)."
    }

    static func empty(isEnabled: Bool, dayKey: String) -> ProductivityMetricsSnapshot {
        ProductivityMetricsSnapshot(
            isEnabled: isEnabled,
            dayKey: dayKey,
            wordsAcceptedToday: 0,
            wordsAcceptedTotal: 0,
            suggestionsAccepted: 0,
            suggestionsDismissed: 0,
            latencySampleCount: 0,
            averageBackendLatencyMs: nil,
            lastLatencyReport: nil
        )
    }
}

@MainActor
protocol ProductivityMetricsRecording: AnyObject {
    func recordAcceptedText(_ text: String)
    func recordDismissedSuggestion()
    func recordBackendLatency(_ latencyMs: Int)
    func recordCompletionLatency(_ report: CompletionLatencyReport)
    func recordInsertionLatency(_ latencyMs: Int)
}

@MainActor
final class LocalProductivityMetricsStore: ObservableObject, ProductivityMetricsRecording {
    @Published private(set) var snapshot: ProductivityMetricsSnapshot

    private let defaults: UserDefaults
    private let key: String
    private let privacyStore: PrivacySettingsStore
    private let calendar: Calendar
    private let now: () -> Date

    init(
        defaults: UserDefaults = .standard,
        key: String = "localProductivityMetrics",
        privacyStore: PrivacySettingsStore,
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init
    ) {
        self.defaults = defaults
        self.key = key
        self.privacyStore = privacyStore
        self.calendar = calendar
        self.now = now

        let today = Self.dayKey(for: now(), calendar: calendar)
        let stored = Self.normalized(Self.load(defaults: defaults, key: key, today: today), today: today)
        Self.save(stored, defaults: defaults, key: key)
        self.snapshot = Self.makeSnapshot(
            from: stored,
            isEnabled: privacyStore.load().productivityMetricsEnabled
        )
    }

    func reload() {
        publish(loadNormalizedStoredMetrics())
    }

    func recordAcceptedText(_ text: String) {
        guard privacyStore.load().productivityMetricsEnabled else {
            reload()
            return
        }

        var stored = loadNormalizedStoredMetrics()
        stored.suggestionsAccepted += 1
        let acceptedWords = Self.acceptedWordCount(in: text)
        stored.wordsAcceptedToday += acceptedWords
        stored.wordsAcceptedTotal += acceptedWords
        saveAndPublish(stored)
    }

    func recordDismissedSuggestion() {
        guard privacyStore.load().productivityMetricsEnabled else {
            reload()
            return
        }

        var stored = loadNormalizedStoredMetrics()
        stored.suggestionsDismissed += 1
        saveAndPublish(stored)
    }

    func recordBackendLatency(_ latencyMs: Int) {
        guard privacyStore.load().productivityMetricsEnabled,
              latencyMs >= 0 else {
            reload()
            return
        }

        var stored = loadNormalizedStoredMetrics()
        stored.latencySampleCount += 1
        stored.latencyTotalMs += latencyMs
        stored.lastLatencyReport = CompletionLatencyReport(backendMs: latencyMs)
        saveAndPublish(stored)
    }

    func recordCompletionLatency(_ report: CompletionLatencyReport) {
        guard privacyStore.load().productivityMetricsEnabled,
              !report.isEmpty else {
            reload()
            return
        }

        var stored = loadNormalizedStoredMetrics()
        if let backendMs = report.backendMs, backendMs >= 0 {
            stored.latencySampleCount += 1
            stored.latencyTotalMs += backendMs
        }
        stored.lastLatencyReport = report
        saveAndPublish(stored)
    }

    func recordInsertionLatency(_ latencyMs: Int) {
        guard privacyStore.load().productivityMetricsEnabled,
              latencyMs >= 0 else {
            reload()
            return
        }

        var stored = loadNormalizedStoredMetrics()
        stored.lastLatencyReport = (stored.lastLatencyReport ?? CompletionLatencyReport())
            .withInsertionLatency(latencyMs)
        saveAndPublish(stored)
    }

    func reset() {
        let stored = StoredProductivityMetrics(dayKey: Self.dayKey(for: now(), calendar: calendar))
        saveAndPublish(stored)
    }

    static func acceptedWordCount(in text: String) -> Int {
        var count = 0
        var isInsideWord = false
        let wordScalars = CharacterSet.letters
            .union(.decimalDigits)
            .union(.nonBaseCharacters)

        for scalar in text.unicodeScalars {
            if wordScalars.contains(scalar) {
                if !isInsideWord {
                    count += 1
                }
                isInsideWord = true
            } else {
                isInsideWord = false
            }
        }

        return count
    }

    private func loadNormalizedStoredMetrics() -> StoredProductivityMetrics {
        let today = Self.dayKey(for: now(), calendar: calendar)
        let stored = Self.normalized(Self.load(defaults: defaults, key: key, today: today), today: today)
        Self.save(stored, defaults: defaults, key: key)
        return stored
    }

    private func saveAndPublish(_ stored: StoredProductivityMetrics) {
        Self.save(stored, defaults: defaults, key: key)
        publish(stored)
    }

    private func publish(_ stored: StoredProductivityMetrics) {
        snapshot = Self.makeSnapshot(
            from: stored,
            isEnabled: privacyStore.load().productivityMetricsEnabled
        )
    }

    private static func makeSnapshot(
        from stored: StoredProductivityMetrics,
        isEnabled: Bool
    ) -> ProductivityMetricsSnapshot {
        ProductivityMetricsSnapshot(
            isEnabled: isEnabled,
            dayKey: stored.dayKey,
            wordsAcceptedToday: stored.wordsAcceptedToday,
            wordsAcceptedTotal: stored.wordsAcceptedTotal,
            suggestionsAccepted: stored.suggestionsAccepted,
            suggestionsDismissed: stored.suggestionsDismissed,
            latencySampleCount: stored.latencySampleCount,
            averageBackendLatencyMs: stored.averageBackendLatencyMs,
            lastLatencyReport: stored.lastLatencyReport
        )
    }

    private static func load(
        defaults: UserDefaults,
        key: String,
        today: String
    ) -> StoredProductivityMetrics {
        guard let data = defaults.data(forKey: key),
              let stored = try? JSONDecoder().decode(StoredProductivityMetrics.self, from: data) else {
            return StoredProductivityMetrics(dayKey: today)
        }

        return stored
    }

    private static func normalized(
        _ stored: StoredProductivityMetrics,
        today: String
    ) -> StoredProductivityMetrics {
        guard stored.dayKey != today else {
            return stored
        }

        var updated = stored
        updated.dayKey = today
        updated.wordsAcceptedToday = 0
        return updated
    }

    private static func save(
        _ stored: StoredProductivityMetrics,
        defaults: UserDefaults,
        key: String
    ) {
        guard let data = try? JSONEncoder().encode(stored) else {
            return
        }
        defaults.set(data, forKey: key)
    }

    private static func dayKey(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}

private struct StoredProductivityMetrics: Codable, Equatable {
    var dayKey: String
    var wordsAcceptedToday: Int
    var wordsAcceptedTotal: Int
    var suggestionsAccepted: Int
    var suggestionsDismissed: Int
    var latencyTotalMs: Int
    var latencySampleCount: Int
    var lastLatencyReport: CompletionLatencyReport?

    init(
        dayKey: String,
        wordsAcceptedToday: Int = 0,
        wordsAcceptedTotal: Int = 0,
        suggestionsAccepted: Int = 0,
        suggestionsDismissed: Int = 0,
        latencyTotalMs: Int = 0,
        latencySampleCount: Int = 0,
        lastLatencyReport: CompletionLatencyReport? = nil
    ) {
        self.dayKey = dayKey
        self.wordsAcceptedToday = wordsAcceptedToday
        self.wordsAcceptedTotal = wordsAcceptedTotal
        self.suggestionsAccepted = suggestionsAccepted
        self.suggestionsDismissed = suggestionsDismissed
        self.latencyTotalMs = latencyTotalMs
        self.latencySampleCount = latencySampleCount
        self.lastLatencyReport = lastLatencyReport
    }

    var averageBackendLatencyMs: Int? {
        guard latencySampleCount > 0 else {
            return nil
        }
        return Int((Double(latencyTotalMs) / Double(latencySampleCount)).rounded())
    }
}
