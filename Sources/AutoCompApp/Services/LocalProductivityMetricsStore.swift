import AutoCompCore
@preconcurrency import AppKit
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
protocol CompletionMetricsRecording: ProductivityMetricsRecording {
    func recordGeneratedSuggestion()
    func recordShownSuggestion()
    func recordSuppressedSuggestion(reason: String)
}

@MainActor
final class LocalProductivityMetricsStore: ObservableObject, CompletionMetricsRecording {
    @Published private(set) var snapshot: ProductivityMetricsSnapshot

    private let privacyStore: PrivacySettingsStore
    private let calendar: Calendar
    private let now: () -> Date
    private let persistence: CoalescingProductivityMetricsPersistence
    private var storedMetrics: StoredProductivityMetrics
    private var isMetricsEnabled: Bool
    private var terminationObserver: NotificationObserverToken?

    init(
        defaults: UserDefaults = .standard,
        key: String = "localProductivityMetrics",
        privacyStore: PrivacySettingsStore,
        calendar: Calendar = .current,
        now: @escaping () -> Date = Date.init
    ) {
        self.privacyStore = privacyStore
        self.calendar = calendar
        self.now = now

        let defaults = MirroredUserDefaults(primary: defaults)
        let today = Self.dayKey(for: now(), calendar: calendar)
        let stored = Self.normalized(Self.load(defaults: defaults, key: key, today: today), today: today)
        let isMetricsEnabled = privacyStore.load().productivityMetricsEnabled
        let persistence = CoalescingProductivityMetricsPersistence(defaults: defaults, key: key)
        self.persistence = persistence
        self.storedMetrics = stored
        self.isMetricsEnabled = isMetricsEnabled
        self.snapshot = Self.makeSnapshot(
            from: stored,
            isEnabled: isMetricsEnabled
        )
        let terminationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: nil
        ) { [persistence] _ in
            persistence.flush()
        }
        self.terminationObserver = NotificationObserverToken(
            center: .default,
            token: terminationObserver
        )
        persistence.schedule(stored)
    }

    func reload() {
        isMetricsEnabled = privacyStore.load().productivityMetricsEnabled
        normalizeStoredMetricsForToday()
        publish()
    }

    func recordAcceptedText(_ text: String) {
        updateMetrics { stored in
            stored.suggestionsAccepted += 1
            let acceptedWords = Self.acceptedWordCount(in: text)
            stored.wordsAcceptedToday += acceptedWords
            stored.wordsAcceptedTotal += acceptedWords
        }
    }

    func recordGeneratedSuggestion() {
        updateMetrics { stored in
            stored.suggestionsGenerated += 1
        }
    }

    func recordShownSuggestion() {
        updateMetrics { stored in
            stored.suggestionsShown += 1
        }
    }

    func recordSuppressedSuggestion(reason: String) {
        updateMetrics { stored in
            let reason = Self.sanitizedSuppressionReason(reason)
            stored.suppressedReasonCounts[reason, default: 0] += 1
        }
    }

    func recordDismissedSuggestion() {
        updateMetrics { stored in
            stored.suggestionsDismissed += 1
        }
    }

    func recordBackendLatency(_ latencyMs: Int) {
        guard latencyMs >= 0 else { return }

        updateMetrics { stored in
            stored.recordBackendLatencySample(latencyMs)
            stored.lastLatencyReport = CompletionLatencyReport(backendMs: latencyMs)
        }
    }

    func recordCompletionLatency(_ report: CompletionLatencyReport) {
        guard !report.isEmpty else { return }

        updateMetrics { stored in
            if let backendMs = report.backendMs, backendMs >= 0 {
                stored.recordBackendLatencySample(backendMs)
            }
            stored.lastLatencyReport = report
        }
    }

    func recordInsertionLatency(_ latencyMs: Int) {
        guard latencyMs >= 0 else { return }

        updateMetrics { stored in
            stored.lastLatencyReport = (stored.lastLatencyReport ?? CompletionLatencyReport())
                .withInsertionLatency(latencyMs)
        }
    }

    func reset() {
        storedMetrics = StoredProductivityMetrics(dayKey: Self.dayKey(for: now(), calendar: calendar))
        saveAndPublish()
    }

    func flushPendingPersistence() {
        persistence.flush()
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

    private func updateMetrics(_ update: (inout StoredProductivityMetrics) -> Void) {
        isMetricsEnabled = privacyStore.load().productivityMetricsEnabled
        guard isMetricsEnabled else {
            publish()
            return
        }

        normalizeStoredMetricsForToday()
        update(&storedMetrics)
        saveAndPublish()
    }

    private func normalizeStoredMetricsForToday() {
        let today = Self.dayKey(for: now(), calendar: calendar)
        storedMetrics = Self.normalized(storedMetrics, today: today)
    }

    private func saveAndPublish() {
        persistence.schedule(storedMetrics)
        publish()
    }

    private func publish() {
        snapshot = Self.makeSnapshot(
            from: storedMetrics,
            isEnabled: isMetricsEnabled
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
        defaults: MirroredUserDefaults,
        key: String,
        today: String
    ) -> StoredProductivityMetrics {
        guard let stored = defaults.decode(StoredProductivityMetrics.self, forKey: key) else {
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

private struct StoredProductivityMetrics: Codable, Equatable, Sendable {
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

private final class CoalescingProductivityMetricsPersistence: @unchecked Sendable {
    private let defaults: MirroredUserDefaults
    private let key: String
    private let queue = DispatchQueue(label: "com.autocomp.productivity-metrics-persistence")
    private let lock = NSLock()
    private let debounceInterval: DispatchTimeInterval
    private var pendingMetrics: StoredProductivityMetrics?
    private var scheduledWorkItem: DispatchWorkItem?
    private var generation = 0

    init(
        defaults: MirroredUserDefaults,
        key: String,
        debounceInterval: DispatchTimeInterval = .milliseconds(100)
    ) {
        self.defaults = defaults
        self.key = key
        self.debounceInterval = debounceInterval
    }

    func schedule(_ metrics: StoredProductivityMetrics) {
        lock.lock()
        generation += 1
        let scheduledGeneration = generation
        pendingMetrics = metrics
        scheduledWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            self?.persistPendingMetrics(for: scheduledGeneration)
        }
        scheduledWorkItem = workItem
        lock.unlock()

        queue.asyncAfter(deadline: .now() + debounceInterval, execute: workItem)
    }

    func flush() {
        lock.lock()
        generation += 1
        scheduledWorkItem?.cancel()
        scheduledWorkItem = nil
        let metrics = pendingMetrics
        pendingMetrics = nil
        lock.unlock()

        queue.sync {
            if let metrics {
                persist(metrics)
            }
        }
    }

    private func persistPendingMetrics(for scheduledGeneration: Int) {
        lock.lock()
        guard generation == scheduledGeneration else {
            lock.unlock()
            return
        }
        let metrics = pendingMetrics
        pendingMetrics = nil
        scheduledWorkItem = nil
        lock.unlock()

        if let metrics {
            persist(metrics)
        }
    }

    private func persist(_ metrics: StoredProductivityMetrics) {
        try? defaults.encode(metrics, forKey: key)
    }
}

private final class NotificationObserverToken: @unchecked Sendable {
    private let center: NotificationCenter
    private let token: NSObjectProtocol

    init(center: NotificationCenter, token: NSObjectProtocol) {
        self.center = center
        self.token = token
    }

    deinit {
        center.removeObserver(token)
    }
}
