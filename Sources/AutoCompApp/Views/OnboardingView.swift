import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var permissions: PermissionService

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("AutoComp")
                    .font(.largeTitle.weight(.semibold))
                Text("Install, type normally, then press Tab for the next word or Right Shift for the full suggestion.")
                    .foregroundStyle(.secondary)
            }

            PermissionCard(
                title: "Accessibility",
                status: permissions.accessibilityTrusted ? "Enabled" : "Required",
                systemImage: "lock.shield",
                isComplete: permissions.accessibilityTrusted,
                description: "AutoComp uses Accessibility to read the active text field and insert accepted completions.",
                actionTitle: "Enable Accessibility",
                action: permissions.requestAccessibility
            )

            PermissionCard(
                title: "Input Monitoring",
                status: permissions.inputMonitoringAllowed ? "Enabled" : "Required",
                systemImage: "keyboard",
                isComplete: permissions.inputMonitoringAllowed,
                description: permissions.inputMonitoringStatus,
                actionTitle: "Enable Input Monitoring",
                action: permissions.requestInputMonitoring
            )

            PermissionCard(
                title: "Screen Recording",
                status: permissions.screenRecordingAllowed ? "Enabled" : (permissions.screenRecordingNeedsRelaunch ? "Relaunch Required" : "Optional"),
                systemImage: "rectangle.dashed",
                isComplete: permissions.screenRecordingAllowed,
                description: permissions.screenRecordingStatus,
                actionTitle: "Enable Screen Recording",
                action: permissions.requestScreenRecording
            )

            HStack {
                Button {
                    permissions.refresh()
                    controller.start()
                } label: {
                    Label("Recheck", systemImage: "arrow.clockwise")
                }

                Button {
                    permissions.openAccessibilitySettings()
                } label: {
                    Label("Open Privacy Settings", systemImage: "gear")
                }

                if permissions.screenRecordingNeedsRelaunch {
                    Button {
                        controller.relaunch()
                    } label: {
                        Label("Relaunch AutoComp", systemImage: "arrow.triangle.2.circlepath")
                    }
                }

                Spacer()

                Text("AutoComp runs locally. Input collection is off by default.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Running as \(permissions.runtimeBundleID)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Text(permissions.runtimeExecutablePath)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
        }
        .padding(28)
    }
}

private struct PermissionCard: View {
    let title: String
    let status: String
    let systemImage: String
    let isComplete: Bool
    let description: String
    let actionTitle: String
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .foregroundStyle(isComplete ? .green : .orange)
                    .frame(width: 18)

                Text(title)
                    .font(.headline)

                Spacer()

                Text(status)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(isComplete ? .green : .orange)
            }

            Text(description)
                .font(.callout)
                .foregroundStyle(.secondary)

            if !isComplete {
                Button(action: action) {
                    Label(actionTitle, systemImage: "arrow.up.forward.app")
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
