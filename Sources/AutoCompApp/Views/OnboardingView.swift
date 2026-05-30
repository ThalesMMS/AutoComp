import AutoCompCore
import SwiftUI

struct OnboardingView: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var permissions: PermissionService
    @State private var remoteConsentRevision = 0

    var body: some View {
        ScrollView {
            content
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(28)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 440, idealHeight: 560)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 8) {
                Text("AutoComp")
                    .font(.largeTitle.weight(.semibold))
                Text("Install, type normally, then press Tab for the next word or Right Shift for the full suggestion.")
                    .foregroundStyle(.secondary)
            }

            let guidedSetup = GuidedSetupComputer.compute(from: permissions.permissionPresentations)

            GuidedSetupProgressHeader(progress: guidedSetup.progress)

            if let guidance = guidedSetup.currentStep?.relaunchGuidanceBannerMessage {
                GuidedSetupGuidanceBanner(message: guidance)
            }

            VStack(alignment: .leading, spacing: 12) {
                ForEach(guidedSetup.steps) { step in
                    GuidedSetupChecklistRow(
                        step: step,
                        isCurrent: step.id == guidedSetup.currentStepID
                    )
                }
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

            HStack(spacing: 10) {
                GuidedSetupPrimaryActionButton(
                    primaryAction: guidedSetup.primaryAction,
                    permissions: permissions,
                    controller: controller
                )

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
    }

}

private struct GuidedSetupPrimaryActionButton: View {
    let primaryAction: GuidedSetupStep.PrimaryAction
    let permissions: PermissionService
    let controller: AppController

    var body: some View {
        Button(actionTitle) {
            performPrimaryAction()
        }
        .buttonStyle(.borderedProminent)
        .disabled(primaryAction == .none)
        .accessibilityLabel(actionTitle)
    }

    private var actionTitle: String {
        primaryAction.title
    }

    private func performPrimaryAction() {
        switch primaryAction {
        case .requestPermission(let kind):
            // PermissionService handles whether this becomes an inline request or settings deep-link.
            permissions.request(kind)

        case .openSystemSettings(let kind):
            permissions.openSettings(for: kind)

        case .recheck:
            permissions.refresh()
            controller.start()

        case .relaunchApp:
            controller.relaunch()

        case .none:
            break
        }
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

private struct GuidedSetupGuidanceBanner: View {
    let message: String

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrowshape.turn.up.left.circle.fill")
                .foregroundStyle(.orange)
                .font(.title3)
                .padding(.top, 1)

            Text(message)
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)
        }
        .padding(14)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(.orange.opacity(0.25), lineWidth: 1)
        )
        .accessibilityLabel(message)
    }
}

private struct GuidedSetupProgressHeader: View {
    let progress: GuidedSetupProgress

    private var progressText: String {
        guard progress.totalMandatorySteps > 0 else { return "Done" }
        if progress.isComplete {
            return "\(progress.totalMandatorySteps) of \(progress.totalMandatorySteps)"
        }
        return "\(progress.completedMandatorySteps + 1) of \(progress.totalMandatorySteps)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text(progress.isComplete ? "Setup complete" : "Setup progress")
                    .font(.headline)

                Spacer()

                Text(progressText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .accessibilityLabel(progressText)
                    .accessibilityHint("Mandatory setup steps")
            }

            ProgressView(value: progress.fractionComplete)
                .progressViewStyle(.linear)
                .accessibilityLabel("Setup progress")
                .accessibilityValue("\(Int(progress.fractionComplete * 100)) percent")
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
    }
}

private struct GuidedSetupChecklistRow: View {
    let step: GuidedSetupStep
    let isCurrent: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle()
                    .fill(isCurrent ? Color.accentColor : Color.secondary.opacity(0.25))
                    .frame(width: 26, height: 26)

                Text("\(step.number)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isCurrent ? .white : .primary)
            }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(step.title)
                        .font(.headline)

                    if !step.isMandatory {
                        Text("Optional")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                    }

                    Spacer()

                    statusView
                }

                Text(step.detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                if let relaunchDetail = step.relaunchGuidanceDetail {
                    Text(relaunchDetail)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel(relaunchDetail)
                }
            }
        }
        .padding(14)
        .background(
            isCurrent ? AnyShapeStyle(Color.accentColor.opacity(0.12)) : AnyShapeStyle(.regularMaterial),
            in: RoundedRectangle(cornerRadius: 10)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(isCurrent ? Color.accentColor.opacity(0.25) : Color.clear, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var statusView: some View {
        switch step.status {
        case .complete:
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill")
                Text("Done")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.green)
        case .incomplete:
            HStack(spacing: 6) {
                Image(systemName: "circle")
                Text("Not set")
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(isCurrent ? .primary : .secondary)
        case .blocked(let label):
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                Text(label)
            }
            .font(.caption.weight(.medium))
            .foregroundStyle(.orange)
        }
    }
}
