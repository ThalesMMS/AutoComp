import AutoCompCore
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var permissions: PermissionService
    @State private var remoteConsentRevision = 0

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

            if !controller.completionBackendSettings.remoteConsentRequirements.isEmpty {
                RemoteConsentCard(
                    settings: controller.completionBackendSettings,
                    hasConsent: { scope in
                        controller.hasRemoteCompletionConsent(
                            for: scope,
                            settings: controller.completionBackendSettings
                        )
                    },
                    grantConsent: { scope in
                        controller.grantRemoteCompletionConsent(
                            for: scope,
                            settings: controller.completionBackendSettings
                        )
                        remoteConsentRevision += 1
                    },
                    resetConsent: {
                        controller.resetRemoteCompletionConsent()
                        remoteConsentRevision += 1
                    }
                )
                .id(remoteConsentRevision)
            }

            HStack {
                Button {
                    permissions.refresh()
                    controller.start()
                } label: {
                    Label("Recheck", systemImage: "arrow.clockwise")
                }

                Button {
                    permissions.openSettings(for: nextIncompletePermission?.kind ?? .accessibility)
                } label: {
                    Label("Open Next Settings", systemImage: "gear")
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

    private var nextIncompletePermission: PermissionPresentation? {
        permissions.permissionPresentations.first { !$0.isComplete && $0.requirement == .required }
            ?? permissions.permissionPresentations.first { !$0.isComplete }
    }
}

private struct RemoteConsentCard: View {
    let settings: CompletionBackendSettings
    let hasConsent: (RemoteCompletionConsentScope) -> Bool
    let grantConsent: (RemoteCompletionConsentScope) -> Void
    let resetConsent: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: "network.badge.shield.half.filled")
                    .foregroundStyle(.orange)
                    .frame(width: 18)
                Text("Remote completion consent")
                    .font(.headline)
                Spacer()
            }

            LabeledContent("Remote endpoint", value: settings.remoteBaseURL)
            LabeledContent("Endpoint type", value: settings.remoteConsentEndpointKindTitle)
            Text("Before remote completion runs, choose whether text from the active field may be sent to this endpoint.")
                .font(.callout)
                .foregroundStyle(.secondary)

            ForEach(settings.remoteConsentRequirements) { requirement in
                let isAllowed = hasConsent(requirement.scope)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text(requirement.title)
                            .font(.caption.weight(.medium))
                        Spacer()
                        Text(isAllowed ? "Allowed" : "Needs consent")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(isAllowed ? .green : .orange)
                    }
                    Text(requirement.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !isAllowed {
                        Button(requirement.buttonTitle) {
                            grantConsent(requirement.scope)
                        }
                    }
                }
            }

            Button("Reset Remote Completion Consent", role: .destructive, action: resetConsent)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
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

                Text(permission.requirementTitle)
                    .font(.caption.weight(.medium))
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(.quaternary, in: Capsule())

                Spacer()

                Text(permission.statusTitle)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(permission.isComplete ? .green : .orange)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text(permission.requirementDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
