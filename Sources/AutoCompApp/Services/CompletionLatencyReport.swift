import Foundation

extension Duration {
    var appMilliseconds: Int {
        let components = components
        return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    }
}

struct CompletionLatencyMetricRow: Codable, Equatable, Sendable {
    let key: String
    let title: String
    let valueMs: Int?

    var diagnosticValue: String {
        valueMs.map { "\($0) ms" } ?? "not measured"
    }
}

struct FocusContextLatencyReport: Equatable, Sendable {
    var axCaptureMs: Int?
    var geometryMs: Int?
}

protocol FocusContextLatencyReporting: AnyObject {
    var lastFocusContextLatencyReport: FocusContextLatencyReport? { get }
}

struct CompletionLatencyReport: Codable, Equatable, Sendable {
    var axCaptureMs: Int?
    var geometryMs: Int?
    var visualContextMs: Int?
    var clipboardFilterMs: Int?
    var debounceMs: Int?
    var backendMs: Int?
    var normalizationMs: Int?
    var overlayMs: Int?
    var insertionMs: Int?
    var totalMs: Int?

    var isEmpty: Bool {
        stageRows.allSatisfy { $0.valueMs == nil }
    }

    var stageRows: [CompletionLatencyMetricRow] {
        [
            CompletionLatencyMetricRow(key: "axCaptureMs", title: "AX capture", valueMs: axCaptureMs),
            CompletionLatencyMetricRow(key: "geometryMs", title: "Geometry", valueMs: geometryMs),
            CompletionLatencyMetricRow(key: "visualContextMs", title: "Visual context", valueMs: visualContextMs),
            CompletionLatencyMetricRow(key: "clipboardFilterMs", title: "Clipboard filter", valueMs: clipboardFilterMs),
            CompletionLatencyMetricRow(key: "debounceMs", title: "Debounce", valueMs: debounceMs),
            CompletionLatencyMetricRow(key: "backendMs", title: "Backend", valueMs: backendMs),
            CompletionLatencyMetricRow(key: "normalizationMs", title: "Normalization", valueMs: normalizationMs),
            CompletionLatencyMetricRow(key: "overlayMs", title: "Overlay", valueMs: overlayMs),
            CompletionLatencyMetricRow(key: "insertionMs", title: "Insertion", valueMs: insertionMs),
            CompletionLatencyMetricRow(key: "totalMs", title: "Total", valueMs: totalMs)
        ]
    }

    var menuSummary: String {
        let total = formatted(totalMs)
        let backend = formatted(backendMs)
        let overlay = formatted(overlayMs)
        return "latest total \(total), backend \(backend), overlay \(overlay)"
    }

    var redactedReport: String {
        let lines = stageRows.map { "\($0.key)=\($0.valueMs.map(String.init) ?? "not-measured")" }
        return ([
            "AutoComp redacted latency report",
            "No text, prompts, OCR, clipboard content, app names, bundle IDs, domains, model output, or suggestions are included."
        ] + lines).joined(separator: "\n")
    }

    func withInsertionLatency(_ latencyMs: Int) -> CompletionLatencyReport {
        var updated = self
        updated.insertionMs = max(0, latencyMs)
        return updated
    }

    private func formatted(_ value: Int?) -> String {
        value.map { "\($0) ms" } ?? "not measured"
    }
}
