import AutoCompCore
import SwiftUI

struct MenuBarContentView: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var permissions: PermissionService
    @EnvironmentObject private var engine: SuggestionEngine
    @EnvironmentObject private var installationLocation: InstallationLocationService
    let canCheckForUpdates: Bool
    let checkForUpdates: () -> Void

    init(
        canCheckForUpdates: Bool = false,
        checkForUpdates: @escaping () -> Void = {}
    ) {
        self.canCheckForUpdates = canCheckForUpdates
        self.checkForUpdates = checkForUpdates
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("AutoComp", systemImage: "text.cursor")
                    .font(.headline)

                Spacer()

                StatusDot(isEnabled: permissions.accessibilityTrusted && engine.isAutocompleteEnabled)
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

                LabeledContent("Backend", value: engine.backendStatusSummary.menuTitle)
                    .font(.caption)
            }

            Divider()

            if installationLocation.status.shouldWarn {
                InstallationLocationWarning(
                    status: installationLocation.status,
                    openApplications: {
                        installationLocation.openApplicationsFolder()
                    },
                    revealCurrentApp: {
                        installationLocation.revealCurrentApp()
                    }
                )

                Divider()
            }

            MenuStatusSection(snapshot: menuStatusSnapshot)

            Divider()

            VStack(alignment: .leading, spacing: 5) {
                Label("Diagnostics", systemImage: "stethoscope")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                ForEach(engine.diagnostics.menuRows) { row in
                    HStack(alignment: .firstTextBaseline) {
                        Text(row.title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(row.value)
                            .font(.caption2)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }
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
                checkForUpdates()
            } label: {
                Label("Check for Updates...", systemImage: "arrow.down.circle")
            }
            .disabled(!canCheckForUpdates)

            Button {
                engine.hideSuggestion()
            } label: {
                Label("Hide Suggestion", systemImage: "eye.slash")
            }

            Button {
                controller.toggleAutocompleteEnabled()
            } label: {
                Label(
                    engine.isAutocompleteEnabled ? "Disable AutoComp" : "Enable AutoComp",
                    systemImage: engine.isAutocompleteEnabled ? "pause.circle" : "play.circle"
                )
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

    private var menuStatusSnapshot: MenuStatusSnapshot {
        let focus = engine.diagnostics.focus
        let decision = focus.map {
            controller.compatibilityCatalog.decision(
                bundleID: $0.bundleID,
                domain: $0.domain,
                userModeOverrides: controller.compatibilitySettings.loadModeOverrides()
            )
        }

        return MenuStatusSnapshot.make(
            accessibilityTrusted: permissions.accessibilityTrusted,
            inputMonitoringAllowed: permissions.inputMonitoringAllowed,
            backendStatusSummary: engine.backendStatusSummary,
            inputMethod: engine.diagnostics.inputMethod,
            focus: focus,
            focusFailure: engine.diagnostics.focusFailure,
            lastDecision: engine.diagnostics.lastDecision,
            compatibilityDecision: decision,
            autocompleteEnabled: engine.isAutocompleteEnabled,
            productivityMetrics: controller.productivityMetricsStore.snapshot
        )
    }
}

private struct InstallationLocationWarning: View {
    let status: InstallationLocationStatus
    let openApplications: () -> Void
    let revealCurrentApp: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Move to Applications", systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)

            Text("Move AutoComp to \(status.recommendedDirectoryPath) before granting macOS permissions.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text("Current: \(status.currentDirectoryPath)")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack {
                Button {
                    openApplications()
                } label: {
                    Label("Open Applications", systemImage: "folder")
                }

                Button {
                    revealCurrentApp()
                } label: {
                    Label("Reveal App", systemImage: "magnifyingglass")
                }
            }
        }
    }
}

private struct MenuStatusSection: View {
    let snapshot: MenuStatusSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Label("Status", systemImage: "gauge")
                .font(.caption)
                .foregroundStyle(.secondary)

            ForEach(snapshot.items) { item in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(item.title)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text(item.value)
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .lineLimit(1)
                    }

                    Text(item.action)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .help(item.action)
            }
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
