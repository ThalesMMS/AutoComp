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

            ForEach(permissions.permissionPresentations) { permission in
                PermissionCard(
                    permission: permission,
                    requestAction: {
                        permissions.request(permission.kind)
                    },
                    openSettingsAction: {
                        permissions.openSettings(for: permission.kind)
                    }
                )
            }

            HStack {
                Button {
                    permissions.refresh()
                    controller.start()
                } label: {
                    Label("Recheck", systemImage: "arrow.clockwise")
                }

                Button {
                    permissions.openSettings(for: .accessibility)
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
    let permission: PermissionPresentation
    let requestAction: () -> Void
    let openSettingsAction: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: permission.systemImage)
                    .foregroundStyle(permission.isComplete ? .green : .orange)
                    .frame(width: 18)

                Text(permission.title)
                    .font(.headline)

                Spacer()

                Text(permission.statusTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(permission.isComplete ? .green : .orange)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Reason")
                    .font(.caption.weight(.medium))
                Text(permission.message)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Next step")
                    .font(.caption.weight(.medium))
                Text(permission.nextActionTitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if !permission.isComplete {
                HStack {
                    Button(action: requestAction) {
                        Label(permission.requestButtonTitle, systemImage: "arrow.up.forward.app")
                    }
                    Button(action: openSettingsAction) {
                        Label(permission.openSettingsButtonTitle, systemImage: "gear")
                    }
                }
            }
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
    }
}
