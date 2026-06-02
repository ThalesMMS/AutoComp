import AutoCompCore
import AppKit
import SwiftUI

struct StatisticsSettingsView: View {
    @EnvironmentObject private var controller: AppController
    @State private var settings = PrivacySettings()

    var body: some View {
        SettingsPaneForm(title: "Statistics") {
            Section("Local metrics") {
                Toggle("Keep local productivity counters", isOn: privacyBinding(\.productivityMetricsEnabled))
                ProductivityMetricsSettingsSummary(
                    metrics: controller.productivityMetricsStore,
                    reset: {
                        controller.resetProductivityMetrics()
                    }
                )
            }
        }
        .onAppear {
            settings = controller.privacySettingsStore.load()
        }
    }

    private func privacyBinding(_ keyPath: WritableKeyPath<PrivacySettings, Bool>) -> Binding<Bool> {
        Binding {
            settings[keyPath: keyPath]
        } set: { value in
            var updatedSettings = settings
            updatedSettings[keyPath: keyPath] = value
            settings = updatedSettings
            controller.savePrivacySettings(updatedSettings)
        }
    }
}

private struct ProductivityMetricsSettingsSummary: View {
    @ObservedObject var metrics: LocalProductivityMetricsStore
    let reset: () -> Void

    var body: some View {
        let snapshot = metrics.snapshot

        SettingsActionRow(
            title: "Status",
            state: snapshot.isEnabled ? .ok : .disabled,
            statusTitle: snapshot.isEnabled ? "On" : "Off"
        )
        LabeledContent("Words today", value: "\(snapshot.wordsAcceptedToday)")
        LabeledContent("Words total", value: "\(snapshot.wordsAcceptedTotal)")
        LabeledContent("Suggestions generated", value: "\(snapshot.suggestionsGenerated)")
        LabeledContent("Suggestions shown", value: "\(snapshot.suggestionsShown)")
        LabeledContent("Suggestions accepted", value: "\(snapshot.suggestionsAccepted)")
        LabeledContent("Suggestions dismissed", value: "\(snapshot.suggestionsDismissed)")
        LabeledContent("Average backend latency", value: averageLatencyTitle(snapshot.averageBackendLatencyMs))
        LabeledContent("Backend latency p50", value: averageLatencyTitle(snapshot.p50BackendLatencyMs))
        LabeledContent("Backend latency p95", value: averageLatencyTitle(snapshot.p95BackendLatencyMs))
        if !snapshot.suppressedReasonCounts.isEmpty {
            DisclosureGroup("Suppressed reasons") {
                ForEach(suppressedReasonRows(snapshot), id: \.reason) { row in
                    LabeledContent(row.reason, value: "\(row.count)")
                }
            }
        }
        if let latencyReport = snapshot.lastLatencyReport {
            Text("Latest latency report")
                .font(.caption.weight(.medium))
            Text(latencyReport.redactedReport)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button("Copy Redacted Latency Report") {
                copyLatencyReport(latencyReport)
            }
        } else {
            SectionFooterNote(text: "No latency report yet.")
        }
        DisclosureGroup("Storage details") {
            SectionFooterNote(text: "Counters and latency reports are stored locally as numbers only. Accepted text, prompts, suggestions, clipboard, OCR, app names, bundle IDs, and domains are not stored in metrics.")
        }
        Button("Reset Productivity Metrics", role: .destructive) {
            reset()
        }
        .disabled(!hasMetrics(snapshot))
    }

    private func averageLatencyTitle(_ latencyMs: Int?) -> String {
        latencyMs.map { "\($0) ms" } ?? "No samples"
    }

    private func hasMetrics(_ snapshot: ProductivityMetricsSnapshot) -> Bool {
            snapshot.wordsAcceptedToday > 0
            || snapshot.wordsAcceptedTotal > 0
            || snapshot.suggestionsGenerated > 0
            || snapshot.suggestionsShown > 0
            || snapshot.suggestionsAccepted > 0
            || snapshot.suggestionsDismissed > 0
            || !snapshot.suppressedReasonCounts.isEmpty
            || snapshot.latencySampleCount > 0
            || snapshot.lastLatencyReport != nil
    }

    private func suppressedReasonRows(_ snapshot: ProductivityMetricsSnapshot) -> [(reason: String, count: Int)] {
        snapshot.suppressedReasonCounts
            .map { (reason: $0.key, count: $0.value) }
            .sorted {
                if $0.count == $1.count {
                    return $0.reason < $1.reason
                }
                return $0.count > $1.count
            }
    }

    private func copyLatencyReport(_ report: CompletionLatencyReport) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.redactedReport, forType: .string)
    }
}
