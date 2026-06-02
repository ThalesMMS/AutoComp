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
        VStack(alignment: .leading, spacing: 12) {
            MenuHeader(
                title: menuStatusTitle,
                subtitle: menuStatusSubtitle,
                state: menuStatusState,
                accessibilityLabel: menuStatusAccessibilityLabel
            )

            Divider()

            MenuPrimaryActions(
                autocompleteEnabled: engine.isAutocompleteEnabled,
                canCheckForUpdates: canCheckForUpdates,
                toggleAutocomplete: {
                    controller.toggleAutocompleteEnabled()
                },
                openSettings: {
                    controller.showSettingsWindow()
                },
                runSetup: {
                    controller.showOnboardingWindow()
                },
                openHealth: openHealthDashboard,
                checkForUpdates: checkForUpdates
            )

            if installationLocation.status.shouldWarn {
                Divider()

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

            MenuCompactSummarySection(
                backend: backendSummaryTitle,
                permissions: permissionSummaryTitle,
                focusedApp: focusedAppTitle,
                openDetails: openHealthDashboard
            )

            Divider()

            Button {
                engine.hideSuggestion()
            } label: {
                Label("Hide Suggestion", systemImage: "eye.slash")
            }

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit AutoComp", systemImage: "power")
            }
        }
        .padding()
        .frame(width: 300)
    }

    private var menuStatusTitle: String {
        if !engine.isAutocompleteEnabled {
            return "Autocomplete off"
        }
        if !permissions.accessibilityTrusted || !permissions.inputMonitoringAllowed {
            return "Setup needed"
        }
        switch engine.backendStatusSummary.state {
        case .connected:
            return engine.diagnostics.focus == nil ? "Waiting for text" : "Ready"
        case .paused:
            return "Backend paused"
        case .disconnected:
            return "Backend issue"
        }
    }

    private var menuStatusSubtitle: String {
        if !engine.isAutocompleteEnabled {
            return "Use the menu toggle when you need suggestions again."
        }
        if !permissions.accessibilityTrusted || !permissions.inputMonitoringAllowed {
            return "Run setup to finish required permissions."
        }
        if let latency = engine.lastLatencyMs {
            return "\(latency) ms last completion"
        }
        return engine.backendStatusSummary.menuTitle
    }

    private var menuStatusState: SettingsVisualState {
        if !engine.isAutocompleteEnabled {
            return .disabled
        }
        if !permissions.accessibilityTrusted || !permissions.inputMonitoringAllowed {
            return .warning
        }
        return SettingsVisualState.backend(engine.backendStatusSummary.state)
    }

    private var menuStatusAccessibilityLabel: String {
        "\(menuStatusTitle). \(menuStatusSubtitle)"
    }

    private var backendSummaryTitle: String {
        engine.backendStatusSummary.menuTitle
    }

    private var permissionSummaryTitle: String {
        let missingCount = [
            permissions.accessibilityTrusted,
            permissions.inputMonitoringAllowed
        ].filter { !$0 }.count

        switch missingCount {
        case 0:
            return "Ready"
        case 1 where !permissions.accessibilityTrusted:
            return "Accessibility needed"
        case 1:
            return "Input Monitoring needed"
        default:
            return "\(missingCount) required permissions missing"
        }
    }

    private var focusedAppTitle: String {
        if let focus = engine.diagnostics.focus {
            return focus.appDisplayName
        }
        if let focusFailure = engine.diagnostics.focusFailure {
            return focusFailure.status.rawValue.capitalized
        }
        return "No focused text field"
    }

    private func openHealthDashboard() {
        controller.showSettingsWindow()
        controller.selectedSettingsSection = .health
    }
}

private struct MenuHeader: View {
    let title: String
    let subtitle: String
    let state: SettingsVisualState
    let accessibilityLabel: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "text.cursor")
                .font(.title3)
                .foregroundStyle(Color.accentColor)
                .frame(width: 22)

            VStack(alignment: .leading, spacing: 2) {
                Text("AutoComp")
                    .font(.headline)
                Text(title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer(minLength: 0)

            StatusDot(state: state, label: accessibilityLabel)
        }
    }
}

private struct MenuPrimaryActions: View {
    let autocompleteEnabled: Bool
    let canCheckForUpdates: Bool
    let toggleAutocomplete: () -> Void
    let openSettings: () -> Void
    let runSetup: () -> Void
    let openHealth: () -> Void
    let checkForUpdates: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: toggleAutocomplete) {
                Label(
                    autocompleteEnabled ? "Disable Autocomplete" : "Enable Autocomplete",
                    systemImage: autocompleteEnabled ? "pause.circle" : "play.circle"
                )
            }

            Button(action: openSettings) {
                Label("Open Settings...", systemImage: "gearshape")
            }

            Button(action: runSetup) {
                Label("Run Setup...", systemImage: "sparkles")
            }

            Button(action: openHealth) {
                Label("Health Dashboard", systemImage: SettingsSection.health.systemImage)
            }

            Button(action: checkForUpdates) {
                Label("Check for Updates...", systemImage: "arrow.down.circle")
            }
            .disabled(!canCheckForUpdates)
        }
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

private struct MenuCompactSummarySection: View {
    let backend: String
    let permissions: String
    let focusedApp: String
    let openDetails: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Summary", systemImage: "gauge")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("View details...", action: openDetails)
                    .font(.caption)
            }

            MenuSummaryRow(title: "Backend", value: backend)
            MenuSummaryRow(title: "Permissions", value: permissions)
            MenuSummaryRow(title: "Focused app", value: focusedApp)
        }
    }
}

private struct MenuSummaryRow: View {
    let title: String
    let value: String

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer(minLength: 10)
            Text(value)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .multilineTextAlignment(.trailing)
        }
    }
}
