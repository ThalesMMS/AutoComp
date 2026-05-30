import AutoCompCore
import AppKit
import SwiftUI

struct HealthDashboardView: View {
    @EnvironmentObject private var controller: AppController

    @State private var expandedCheckIDs: Set<String> = []
    @State private var instructionsToShow: HealthRemediationAction?

    private var snapshot: HealthSnapshot {
        controller.healthSnapshotService.snapshot
    }

    private var groupedChecks: [(status: HealthStatus, checks: [HealthCheck])] {
        let order: [HealthStatus] = [.fail, .warn, .unknown, .ok]
        let grouped = Dictionary(grouping: snapshot.checks, by: \ .status)
        return order.compactMap { status in
            guard let checks = grouped[status], !checks.isEmpty else { return nil }
            return (status, checks)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            focusedAppSection

            if snapshot.checks.isEmpty {
                ContentUnavailableView(
                    "Health checks unavailable",
                    systemImage: "heart.slash",
                    description: Text("AutoComp couldn't produce health results yet. Try Refresh.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(groupedChecks, id: \ .status) { group in
                            healthSection(for: group.status, checks: group.checks)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
        .padding()
        .navigationTitle("Health")
        .alert(
            instructionsToShow?.title ?? "Instructions",
            isPresented: Binding(
                get: { instructionsToShow != nil },
                set: { presented in
                    if !presented {
                        instructionsToShow = nil
                    }
                }
            ),
            actions: {
                Button("OK") {
                    instructionsToShow = nil
                }
            },
            message: {
                Text(instructionsToShow?.payload ?? "")
            }
        )
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Setup status")
                    .font(.title2.weight(.semibold))
                Text("Checks update automatically. Use Refresh if something changed recently.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Refresh") {
                controller.healthSnapshotService.refresh()
            }
            .keyboardShortcut("r")
        }
    }

    @ViewBuilder
    private func healthSection(for status: HealthStatus, checks: [HealthCheck]) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(sectionTitle(for: status))
                .font(.headline)

            ForEach(checks) { check in
                checkRow(check)
            }
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    private func sectionTitle(for status: HealthStatus) -> String {
        switch status {
        case .fail:
            return "Needs attention"
        case .warn:
            return "Recommended"
        case .unknown:
            return "Unknown"
        case .ok:
            return "All good"
        }
    }

    @ViewBuilder
    private func checkRow(_ check: HealthCheck) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                statusIndicator(for: check.status)
                    .padding(.top, 2)

                VStack(alignment: .leading, spacing: 2) {
                    Text(check.title)
                        .font(.body.weight(.semibold))
                    Text(check.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 8)

                if check.details != nil {
                    Button(expandedCheckIDs.contains(check.id) ? "Hide" : "Details") {
                        toggleExpanded(check.id)
                    }
                    .buttonStyle(.borderless)
                }
            }

            if expandedCheckIDs.contains(check.id) {
                if let details = check.details {
                    Text(details)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                if !check.actions.isEmpty {
                    actionButtons(for: check.actions)
                }
            }
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func toggleExpanded(_ id: String) {
        if expandedCheckIDs.contains(id) {
            expandedCheckIDs.remove(id)
        } else {
            expandedCheckIDs.insert(id)
        }
    }

    @ViewBuilder
    private func statusIndicator(for status: HealthStatus) -> some View {
        let (color, symbol): (Color, String) = {
            switch status {
            case .ok:
                return (.green, "checkmark.circle.fill")
            case .warn:
                return (.orange, "exclamationmark.triangle.fill")
            case .fail:
                return (.red, "xmark.octagon.fill")
            case .unknown:
                return (.secondary, "questionmark.diamond.fill")
            }
        }()

        Image(systemName: symbol)
            .foregroundStyle(color)
    }

    @ViewBuilder
    private func actionButtons(for actions: [HealthRemediationAction]) -> some View {
        HStack(alignment: .center, spacing: 8) {
            ForEach(actions) { action in
                Button(action.title) {
                    perform(action)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }
        }
    }

    private func perform(_ action: HealthRemediationAction) {
        switch action.kind {
        case .openURL, .openSystemSettings:
            guard let url = action.url else {
                NSSound.beep()
                return
            }
            NSWorkspace.shared.open(url)

        case .openInAppSettings:
            guard let payload = action.payload else {
                NSSound.beep()
                return
            }
            navigateToInAppSettings(payload)

        case .retry:
            performRetry(payload: action.payload)

        case .showInstructions:
            instructionsToShow = action
        }
    }

    private func navigateToInAppSettings(_ payload: String) {
        switch payload {
        case "settings.backend":
            controller.selectedSettingsSection = .model

        case "settings.compatibility":
            controller.selectedSettingsSection = .apps

        default:
            NSSound.beep()
        }
    }

    private var focusedAppSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Focused app")
                .font(.headline)

            if let check = snapshot.checks.first(where: { $0.id == HostAppCompatibilityHealthCheck.id }) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top, spacing: 10) {
                        statusIndicator(for: check.status)
                            .padding(.top, 2)

                        VStack(alignment: .leading, spacing: 2) {
                            Text(check.summary)
                                .font(.body.weight(.semibold))
                            Text(check.details ?? "")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(3)
                        }

                        Spacer(minLength: 8)

                        if check.details != nil {
                            Button(expandedCheckIDs.contains(check.id) ? "Hide" : "Details") {
                                toggleExpanded(check.id)
                            }
                            .buttonStyle(.borderless)
                        }
                    }

                    if expandedCheckIDs.contains(check.id) {
                        if let details = check.details {
                            Text(details)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                        }

                        if !check.actions.isEmpty {
                            actionButtons(for: check.actions)
                        }
                    }
                }
                .padding(10)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
            } else {
                Text("No focused app information yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.15), lineWidth: 1)
        )
    }

    private func performRetry(payload: String?) {
        guard let payload else {
            controller.healthSnapshotService.refresh()
            return
        }

        switch payload {
        case "backend.test-connection":
            controller.selectedSettingsSection = .model
            controller.healthSnapshotService.refresh()

        default:
            controller.healthSnapshotService.refresh()
        }
    }
}
