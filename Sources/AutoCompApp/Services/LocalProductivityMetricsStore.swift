import AutoCompCore
import Combine
import Foundation

struct ProductivityMetricsSnapshot: Equatable {
    let isEnabled: Bool
    let dayKey: String
    let suggestionsGenerated: Int
    let suggestionsShown: Int
    let wordsAcceptedToday: Int
    let wordsAcceptedTotal: Int
    let suggestionsAccepted: Int
    let suggestionsDismissed: Int
    let suppressedReasonCounts: [String: Int]
    let latencySampleCount: Int
    let averageBackendLatencyMs: Int?
    let p50BackendLatencyMs: Int?
    let p95BackendLatencyMs: Int?
    let lastLatencyReport: CompletionLatencyReport?

    init(
        isEnabled: Bool,
        dayKey: String,
        suggestionsGenerated: Int = 0,
        suggestionsShown: Int = 0,
        wordsAcceptedToday: Int,
        wordsAcceptedTotal: Int,
        suggestionsAccepted: Int,
        suggestionsDismissed: Int,
        suppressedReasonCounts: [String: Int] = [:],
        latencySampleCount: Int,
        averageBackendLatencyMs: Int?,
        p50BackendLatencyMs: Int? = nil,
        p95BackendLatencyMs: Int? = nil,
        lastLatencyReport: CompletionLatencyReport? = nil
    ) {
        self.isEnabled = isEnabled
        self.dayKey = dayKey
        self.suggestionsGenerated = suggestionsGenerated
        self.suggestionsShown = suggestionsShown
        self.wordsAcceptedToday = wordsAcceptedToday
        self.wordsAcceptedTotal = wordsAcceptedTotal
        self.suggestionsAccepted = suggestionsAccepted
        self.suggestionsDismissed = suggestionsDismissed
        self.suppressedReasonCounts = suppressedReasonCounts
        self.latencySampleCount = latencySampleCount
        self.averageBackendLatencyMs = averageBackendLatencyMs
        self.p50BackendLatencyMs = p50BackendLatencyMs
        self.p95BackendLatencyMs = p95BackendLatencyMs
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
        return "\(wordsAcceptedTotal) total words, \(suggestionsGenerated) generated, \(suggestionsShown) shown, \(suggestionsAccepted) accepted, \(suggestionsDismissed) dismissed, \(latency)."
    }

    static func empty(isEnabled: Bool, dayKey: String) -> ProductivityMetricsSnapshot {
        ProductivityMetricsSnapshot(
            isEnabled: isEnabled,
            dayKey: dayKey,
            suggestionsGenerated: 0,
            suggestionsShown: 0,
            wordsAcceptedToday: 0,
            wordsAcceptedTotal: 0,
            suggestionsAccepted: 0,
            suggestionsDismissed: 0,
            suppressedReasonCounts: [:],
            latencySampleCount: 0,
            averageBackendLatencyMs: nil,
            p50BackendLatencyMs: nil,
            p95BackendLatencyMs: nil,
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
protocol CompletionTelemetryMetricsRecording: ProductivityMetricsRecording {
    func recordGeneratedSuggestion()
    func recordShownSuggestion()
    func recordSuppressedSuggestion(reason: String)
}

@MainActor
final class LocalProductivityMetricsStore: ObservableObject, CompletionTelemetryMetricsRecording {
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

    func recordGeneratedSuggestion() {
        guard privacyStore.load().productivityMetricsEnabled else {
            reload()
            return
        }

        var stored = loadNormalizedStoredMetrics()
        stored.suggestionsGenerated += 1
        saveAndPublish(stored)
    }

    func recordShownSuggestion() {
        guard privacyStore.load().productivityMetricsEnabled else {
            reload()
            return
        }

        var stored = loadNormalizedStoredMetrics()
        stored.suggestionsShown += 1
        saveAndPublish(stored)
    }

    func recordSuppressedSuggestion(reason: String) {
        guard privacyStore.load().productivityMetricsEnabled else {
            reload()
            return
        }

        let reason = Self.sanitizedSuppressionReason(reason)
        var stored = loadNormalizedStoredMetrics()
        stored.suppressedReasonCounts[reason, default: 0] += 1
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
        stored.recordBackendLatencySample(latencyMs)
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
            stored.recordBackendLatencySample(backendMs)
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
            suggestionsGenerated: stored.suggestionsGenerated,
            suggestionsShown: stored.suggestionsShown,
            wordsAcceptedToday: stored.wordsAcceptedToday,
            wordsAcceptedTotal: stored.wordsAcceptedTotal,
            suggestionsAccepted: stored.suggestionsAccepted,
            suggestionsDismissed: stored.suggestionsDismissed,
            suppressedReasonCounts: stored.suppressedReasonCounts,
            latencySampleCount: stored.latencySampleCount,
            averageBackendLatencyMs: stored.averageBackendLatencyMs,
            p50BackendLatencyMs: stored.p50BackendLatencyMs,
            p95BackendLatencyMs: stored.p95BackendLatencyMs,
            lastLatencyReport: stored.lastLatencyReport
        )
    }

    private static func sanitizedSuppressionReason(_ reason: String) -> String {
        let lowercased = reason.lowercased()
        let allowedPunctuation = CharacterSet(charactersIn: "-_.:")
        guard lowercased.unicodeScalars.allSatisfy({
            CharacterSet.alphanumerics.contains($0) || allowedPunctuation.contains($0)
        }) else {
            return "other"
        }

        let sanitized = lowercased.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return String((sanitized.isEmpty ? "other" : sanitized).prefix(64))
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
    private static let maxLatencySamples = 200

    var dayKey: String
    var suggestionsGenerated: Int
    var suggestionsShown: Int
    var wordsAcceptedToday: Int
    var wordsAcceptedTotal: Int
    var suggestionsAccepted: Int
    var suggestionsDismissed: Int
    var suppressedReasonCounts: [String: Int]
    var latencyTotalMs: Int
    var latencySampleCount: Int
    var backendLatencySamples: [Int]
    var lastLatencyReport: CompletionLatencyReport?

    init(
        dayKey: String,
        suggestionsGenerated: Int = 0,
        suggestionsShown: Int = 0,
        wordsAcceptedToday: Int = 0,
        wordsAcceptedTotal: Int = 0,
        suggestionsAccepted: Int = 0,
        suggestionsDismissed: Int = 0,
        suppressedReasonCounts: [String: Int] = [:],
        latencyTotalMs: Int = 0,
        latencySampleCount: Int = 0,
        backendLatencySamples: [Int] = [],
        lastLatencyReport: CompletionLatencyReport? = nil
    ) {
        self.dayKey = dayKey
        self.suggestionsGenerated = suggestionsGenerated
        self.suggestionsShown = suggestionsShown
        self.wordsAcceptedToday = wordsAcceptedToday
        self.wordsAcceptedTotal = wordsAcceptedTotal
        self.suggestionsAccepted = suggestionsAccepted
        self.suggestionsDismissed = suggestionsDismissed
        self.suppressedReasonCounts = suppressedReasonCounts
        self.latencyTotalMs = latencyTotalMs
        self.latencySampleCount = latencySampleCount
        self.backendLatencySamples = Array(backendLatencySamples.suffix(Self.maxLatencySamples))
        self.lastLatencyReport = lastLatencyReport
    }

    private enum CodingKeys: String, CodingKey {
        case dayKey
        case suggestionsGenerated
        case suggestionsShown
        case wordsAcceptedToday
        case wordsAcceptedTotal
        case suggestionsAccepted
        case suggestionsDismissed
        case suppressedReasonCounts
        case latencyTotalMs
        case latencySampleCount
        case backendLatencySamples
        case lastLatencyReport
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            dayKey: try container.decode(String.self, forKey: .dayKey),
            suggestionsGenerated: try container.decodeIfPresent(Int.self, forKey: .suggestionsGenerated) ?? 0,
            suggestionsShown: try container.decodeIfPresent(Int.self, forKey: .suggestionsShown) ?? 0,
            wordsAcceptedToday: try container.decodeIfPresent(Int.self, forKey: .wordsAcceptedToday) ?? 0,
            wordsAcceptedTotal: try container.decodeIfPresent(Int.self, forKey: .wordsAcceptedTotal) ?? 0,
            suggestionsAccepted: try container.decodeIfPresent(Int.self, forKey: .suggestionsAccepted) ?? 0,
            suggestionsDismissed: try container.decodeIfPresent(Int.self, forKey: .suggestionsDismissed) ?? 0,
            suppressedReasonCounts: try container.decodeIfPresent([String: Int].self, forKey: .suppressedReasonCounts) ?? [:],
            latencyTotalMs: try container.decodeIfPresent(Int.self, forKey: .latencyTotalMs) ?? 0,
            latencySampleCount: try container.decodeIfPresent(Int.self, forKey: .latencySampleCount) ?? 0,
            backendLatencySamples: try container.decodeIfPresent([Int].self, forKey: .backendLatencySamples) ?? [],
            lastLatencyReport: try container.decodeIfPresent(CompletionLatencyReport.self, forKey: .lastLatencyReport)
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(dayKey, forKey: .dayKey)
        try container.encode(suggestionsGenerated, forKey: .suggestionsGenerated)
        try container.encode(suggestionsShown, forKey: .suggestionsShown)
        try container.encode(wordsAcceptedToday, forKey: .wordsAcceptedToday)
        try container.encode(wordsAcceptedTotal, forKey: .wordsAcceptedTotal)
        try container.encode(suggestionsAccepted, forKey: .suggestionsAccepted)
        try container.encode(suggestionsDismissed, forKey: .suggestionsDismissed)
        try container.encode(suppressedReasonCounts, forKey: .suppressedReasonCounts)
        try container.encode(latencyTotalMs, forKey: .latencyTotalMs)
        try container.encode(latencySampleCount, forKey: .latencySampleCount)
        try container.encode(backendLatencySamples, forKey: .backendLatencySamples)
        try container.encodeIfPresent(lastLatencyReport, forKey: .lastLatencyReport)
    }

    mutating func recordBackendLatencySample(_ latencyMs: Int) {
        latencySampleCount += 1
        latencyTotalMs += latencyMs
        backendLatencySamples.append(latencyMs)
        backendLatencySamples = Array(backendLatencySamples.suffix(Self.maxLatencySamples))
    }

    var averageBackendLatencyMs: Int? {
        guard latencySampleCount > 0 else {
            return nil
        }
        return Int((Double(latencyTotalMs) / Double(latencySampleCount)).rounded())
    }

    var p50BackendLatencyMs: Int? {
        percentile(50)
    }

    var p95BackendLatencyMs: Int? {
        percentile(95)
    }

    private func percentile(_ percentile: Int) -> Int? {
        guard !backendLatencySamples.isEmpty else {
            return nil
        }

        let sorted = backendLatencySamples.sorted()
        let clamped = min(100, max(0, percentile))
        let rank = (Double(clamped) / 100.0) * Double(sorted.count - 1)
        return sorted[Int(rank.rounded(.up))]
    }
}
