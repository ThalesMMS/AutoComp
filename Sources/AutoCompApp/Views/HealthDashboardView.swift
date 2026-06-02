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
        let grouped = Dictionary(grouping: snapshot.checks, by: \.status)
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
                        ForEach(groupedChecks, id: \.status) { group in
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
                Text("Refresh after changing permissions, backend, or app settings.")
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
                .foregroundStyle(SettingsVisualState.health(status).tint)

            ForEach(checks) { check in
                checkRow(check)
            }
        }
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
        let nextStep = nextStep(for: check)

        SettingsInfoCard(
            title: check.title,
            subtitle: check.summary,
            state: SettingsVisualState.health(check.status),
            statusTitle: SettingsVisualState.health(check.status).title
        ) {
            SettingsActionRow(
                title: "Next step",
                subtitle: nextStep.title,
                state: nextStep.state,
                statusTitle: nextStep.statusTitle
            )

            if check.details != nil || !check.actions.isEmpty {
                DisclosureGroup(
                    isExpanded: Binding(
                        get: { expandedCheckIDs.contains(check.id) },
                        set: { updateExpansion(check.id, isExpanded: $0) }
                    )
                ) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let details = check.details {
                            SectionFooterNote(text: details)
                                .textSelection(.enabled)
                        }

                        if !check.actions.isEmpty {
                            actionButtons(for: check.actions)
                        }
                    }
                } label: {
                    Text("Technical details")
                }
            }
        }
    }

    private func nextStep(for check: HealthCheck) -> HealthNextStep {
        let state = SettingsVisualState.health(check.status)

        switch check.status {
        case .ok:
            return HealthNextStep(title: "No action needed.", state: .ok, statusTitle: "Ready")

        case .unknown:
            if let action = check.actions.first {
                return HealthNextStep(title: nextStepTitle(for: action), state: state, statusTitle: "Check")
            }
            return HealthNextStep(
                title: "Refresh after focusing an app or changing setup.",
                state: state,
                statusTitle: "Check"
            )

        case .warn, .fail:
            if let action = check.actions.first {
                return HealthNextStep(title: nextStepTitle(for: action), state: state, statusTitle: "Action")
            }
            return HealthNextStep(title: "Review the technical details below.", state: state, statusTitle: "Review")
        }
    }

    private func nextStepTitle(for action: HealthRemediationAction) -> String {
        switch action.kind {
        case .openSystemSettings:
            return "Open System Settings."
        case .openInAppSettings:
            return "\(action.title)."
        case .retry:
            return "Test connection."
        case .showInstructions:
            return "Read the setup instructions."
        case .openURL:
            return "Open the linked page."
        }
    }

    private func updateExpansion(_ id: String, isExpanded: Bool) {
        if isExpanded {
            expandedCheckIDs.insert(id)
        } else {
            expandedCheckIDs.remove(id)
        }
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
        case .openSystemSettings:
            if let kind = permissionKind(forSystemSettingsActionID: action.id) {
                controller.startPermissionGuidance(for: kind)
                return
            }
            guard let url = action.url else {
                NSSound.beep()
                return
            }
            NSWorkspace.shared.open(url)

        case .openURL:
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

    private func permissionKind(forSystemSettingsActionID actionID: String) -> PermissionKind? {
        switch actionID {
        case "open.accessibility.system-settings":
            return .accessibility
        case "open.input-monitoring.system-settings":
            return .inputMonitoring
        case "open.screen-recording.system-settings":
            return .screenRecording
        default:
            return nil
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
                checkRow(check)
            } else {
                SettingsInfoCard(
                    title: "No focused app",
                    subtitle: "No focused app information yet.",
                    state: .pending,
                    systemImage: "app.dashed"
                )
            }
        }
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

private struct HealthNextStep {
    let title: String
    let state: SettingsVisualState
    let statusTitle: String
}
