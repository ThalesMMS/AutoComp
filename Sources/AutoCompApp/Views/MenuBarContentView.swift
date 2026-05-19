import AutoCompCore
import SwiftUI

struct MenuBarContentView: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var permissions: PermissionService
    @EnvironmentObject private var engine: SuggestionEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("AutoComp", systemImage: "text.cursor")
                    .font(.headline)

                Spacer()

                StatusDot(isEnabled: permissions.accessibilityTrusted)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(engine.statusMessage)
                    .font(.callout)
                    .lineLimit(2)

                if let latency = engine.lastLatencyMs {
                    Text("\(latency) ms completion")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Local autocomplete is ready when Accessibility is enabled.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Text(controller.completionBackendSummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Divider()

            Button {
                controller.showOnboardingWindow()
            } label: {
                Label("Open Onboarding", systemImage: "sparkles")
            }

            Button {
                controller.showSettingsWindow()
            } label: {
                Label("Settings", systemImage: "gearshape")
            }

            Button {
                engine.hideSuggestion()
            } label: {
                Label("Hide Suggestion", systemImage: "eye.slash")
            }

            Divider()

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit AutoComp", systemImage: "power")
            }
        }
        .padding()
        .frame(width: 320)
        .onAppear {
            controller.start()
        }
    }
}

private struct StatusDot: View {
    let isEnabled: Bool

    var body: some View {
        Circle()
            .fill(isEnabled ? .green : .orange)
            .frame(width: 9, height: 9)
            .accessibilityLabel(isEnabled ? "Enabled" : "Needs Accessibility permission")
    }
}
