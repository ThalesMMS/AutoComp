import AutoCompCore
import SwiftUI

struct OnboardingView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var permissions: PermissionService
    @State private var selectedStep: OnboardingWizardStep = .welcome
    @State private var remoteConsentRevision = 0
    @State private var shortcutSettings = KeyboardShortcutSettings.defaults

    var body: some View {
        let guidedSetup = GuidedSetupComputer.compute(from: permissions.permissionPresentations)

        VStack(spacing: 0) {
            OnboardingWizardHeader(step: selectedStep)
                .padding(.horizontal, 28)
                .padding(.top, 24)
                .padding(.bottom, 16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    OnboardingStepIntro(step: selectedStep)
                    stepContent(for: selectedStep, guidedSetup: guidedSetup)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(28)
            }

            Divider()

            OnboardingWizardFooter(
                step: selectedStep,
                canGoBack: selectedStep.previous != nil,
                canSkipBackend: selectedStep == .backend && canSkipBackendSetup,
                goBack: goBack,
                skipBackend: goNext,
                openSettings: { openSettings(.general) },
                primaryAction: primaryFooterAction
            )
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 440, idealHeight: 560)
        .onAppear {
            shortcutSettings = controller.shortcutSettingsStore.load()
        }
    }

    @ViewBuilder
    private func stepContent(for step: OnboardingWizardStep, guidedSetup: GuidedSetupState) -> some View {
        switch step {
        case .welcome:
            welcomeStep
        case .permissions:
            permissionsStep(guidedSetup)
        case .backend:
            backendStep
        case .privacy:
            privacyStep
        case .shortcuts:
            shortcutsStep
        case .tryIt:
            tryItStep
        case .done:
            doneStep(guidedSetup)
        }
    }

    private var welcomeStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsActionRow(
                title: "Type normally",
                subtitle: "AutoComp watches supported text fields after setup.",
                state: .ok,
                statusTitle: "Step 1"
            )
            SettingsActionRow(
                title: "Review access",
                subtitle: "Approve only the permissions needed for inline suggestions.",
                state: .pending,
                statusTitle: "Step 2"
            )
            SettingsActionRow(
                title: "Choose controls",
                subtitle: "Confirm backend, privacy, shortcuts, then try a suggestion.",
                state: .pending,
                statusTitle: "Step 3"
            )
        }
    }

    private func permissionsStep(_ guidedSetup: GuidedSetupState) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            GuidedSetupProgressHeader(progress: guidedSetup.progress)

            if let guidance = guidedSetup.currentStep?.relaunchGuidanceBannerMessage {
                GuidedSetupGuidanceBanner(message: guidance)
            }

            VStack(alignment: .leading, spacing: 10) {
                ForEach(guidedSetup.steps) { step in
                    GuidedSetupChecklistRow(
                        step: step,
                        isCurrent: step.id == guidedSetup.currentStepID
                    )
                }
            }

            GuidedSetupPrimaryActionButton(
                primaryAction: guidedSetup.primaryAction,
                permissions: permissions,
                controller: controller
            )
        }
    }

    private var backendStep: some View {
        VStack(alignment: .leading, spacing: 14) {
            let settings = controller.completionBackendSettings
            let surface = BackendSurface(settings: settings)

            SettingsInfoCard(
                title: "Backend / Model",
                subtitle: backendSetupSummary(settings),
                state: canSkipBackendSetup ? .ok : .warning,
                statusTitle: canSkipBackendSetup ? "Ready" : "Needs setup",
                systemImage: "server.rack"
            ) {
                SettingsActionRow(
                    title: "Selected engine",
                    subtitle: settings.engineKind.displayName
                )
                SettingsActionRow(
                    title: "Request destination",
                    subtitle: surface.requestDestinationTitle
                )
                Button("Open Model Settings") {
                    openSettings(.model)
                }
            }

            if !settings.remoteConsentRequirements.isEmpty {
                RemoteConsentCard(
                    settings: settings,
                    hasConsent: { scope in
                        controller.hasRemoteCompletionConsent(
                            for: scope,
                            settings: settings
                        )
                    },
                    grantConsent: { scope in
                        controller.grantRemoteCompletionConsent(
                            for: scope,
                            settings: settings
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

            if canSkipBackendSetup {
                SectionFooterNote(text: "This backend has enough information to continue. You can tune it later in Settings.")
            }
        }
    }

    private var privacyStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsActionRow(
                title: "Local context",
                subtitle: "Clipboard and visible screen text stay off until you enable them.",
                state: .disabled,
                statusTitle: "Off"
            )
            SettingsActionRow(
                title: "Remote requests",
                subtitle: BackendSurface(settings: controller.completionBackendSettings).dataLeavesDeviceTitle,
                state: privacyBackendState,
                statusTitle: privacyBackendStatusTitle
            )
            SettingsActionRow(
                title: "Local data",
                subtitle: "Personalization and counters can be deleted from Privacy.",
                state: .ok,
                statusTitle: "Local"
            )
            Button("Open Privacy Settings") {
                openSettings(.privacy)
            }
        }
    }

    private var shortcutsStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            OnboardingShortcutRow(command: .acceptNextWord, binding: shortcutSettings[.acceptNextWord])
            OnboardingShortcutRow(command: .acceptFullSuggestion, binding: shortcutSettings[.acceptFullSuggestion])
            OnboardingShortcutRow(command: .manualTrigger, binding: shortcutSettings[.manualTrigger])
            Button("Open Shortcut Settings") {
                openSettings(.shortcuts)
            }
        }
    }

    private var tryItStep: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsInfoCard(
                title: "Try a suggestion",
                subtitle: "Open a supported text field, type a sentence, then pause.",
                state: .pending,
                statusTitle: "Try it",
                systemImage: "text.cursor"
            ) {
                SettingsActionRow(
                    title: "Accept next word",
                    subtitle: shortcutSettings[.acceptNextWord].displayName
                )
                SettingsActionRow(
                    title: "Accept full suggestion",
                    subtitle: shortcutSettings[.acceptFullSuggestion].displayName
                )
                SettingsActionRow(
                    title: "If nothing appears",
                    subtitle: "Return to Settings > Health and refresh the checks."
                )
            }
            Button("Open Health Settings") {
                openSettings(.health)
            }
        }
    }

    private func doneStep(_ guidedSetup: GuidedSetupState) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsInfoCard(
                title: "Ready to use AutoComp",
                subtitle: guidedSetup.progress.isComplete
                    ? "Open a supported app and type normally."
                    : "You can start now and finish remaining setup from Settings.",
                state: guidedSetup.progress.isComplete ? .ok : .warning,
                statusTitle: guidedSetup.progress.isComplete ? "Ready" : "Partial",
                systemImage: "checkmark.circle.fill"
            ) {
                SettingsActionRow(
                    title: "Start using AutoComp",
                    subtitle: "The menu bar icon stays available for Settings and diagnostics."
                )
                SettingsActionRow(
                    title: "Open Settings",
                    subtitle: "Review General, Setup, Model, Privacy, and Health any time."
                )
            }
        }
    }

    private var canSkipBackendSetup: Bool {
        let settings = controller.completionBackendSettings
        switch settings.engineKind {
        case .remote:
            return !settings.remoteBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && !settings.remoteModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        case .localLlama:
            let modelPath = settings.localModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
            return !modelPath.isEmpty && FileManager.default.fileExists(atPath: modelPath)
        case .appleIntelligence:
            return true
        }
    }

    private var privacyBackendState: SettingsVisualState {
        let settings = controller.completionBackendSettings
        switch settings.engineKind {
        case .remote:
            return .warning
        case .localLlama:
            return settings.fallbackToRemoteOnLocalFailure ? .warning : .ok
        case .appleIntelligence:
            return settings.fallbackToRemoteOnAppleIntelligenceFailure ? .warning : .ok
        }
    }

    private var privacyBackendStatusTitle: String {
        privacyBackendState == .warning ? "Review" : "Local"
    }

    private func backendSetupSummary(_ settings: CompletionBackendSettings) -> String {
        switch settings.engineKind {
        case .remote:
            return canSkipBackendSetup
                ? "Remote endpoint and model are set."
                : "Add a remote endpoint and model before testing completions."
        case .localLlama:
            return canSkipBackendSetup
                ? "A local model is installed and selected."
                : "Import or download a local GGUF before using local completions."
        case .appleIntelligence:
            return "No model file is required. Availability depends on this Mac."
        }
    }

    private func goBack() {
        if let previous = selectedStep.previous {
            selectedStep = previous
        }
    }

    private func goNext() {
        if let next = selectedStep.next {
            selectedStep = next
        }
    }

    private func primaryFooterAction() {
        if selectedStep == .done {
            finishWizard()
        } else {
            goNext()
        }
    }

    private func finishWizard() {
        controller.start()
        controller.closeOnboardingWindow()
        dismiss()
    }

    private func openSettings(_ section: SettingsSection) {
        controller.selectedSettingsSection = section
        controller.showSettingsWindow()
    }
}

private enum OnboardingWizardStep: Int, CaseIterable, Identifiable {
    case welcome
    case permissions
    case backend
    case privacy
    case shortcuts
    case tryIt
    case done

    var id: String { rawValue.description }

    var title: String {
        switch self {
        case .welcome:
            return "Welcome"
        case .permissions:
            return "Permissions"
        case .backend:
            return "Backend / Model"
        case .privacy:
            return "Privacy"
        case .shortcuts:
            return "Shortcuts"
        case .tryIt:
            return "Try It"
        case .done:
            return "Done"
        }
    }

    var subtitle: String {
        switch self {
        case .welcome:
            return "Set up AutoComp in a few focused steps."
        case .permissions:
            return "Approve the access needed for inline suggestions."
        case .backend:
            return "Confirm where completion requests are generated."
        case .privacy:
            return "Review what stays local and what can be sent."
        case .shortcuts:
            return "Check the keys used to accept or request suggestions."
        case .tryIt:
            return "Try the flow in a supported text field."
        case .done:
            return "Start using AutoComp or open Settings."
        }
    }

    var progressLabel: String {
        "\(rawValue + 1) of \(Self.allCases.count)"
    }

    var progressFraction: Double {
        Double(rawValue + 1) / Double(Self.allCases.count)
    }

    var previous: OnboardingWizardStep? {
        Self(rawValue: rawValue - 1)
    }

    var next: OnboardingWizardStep? {
        Self(rawValue: rawValue + 1)
    }
}

private struct OnboardingWizardHeader: View {
    let step: OnboardingWizardStep

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("AutoComp Setup")
                        .font(.title2.weight(.semibold))
                    Text(step.title)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Text(step.progressLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }

            ProgressView(value: step.progressFraction)
                .progressViewStyle(.linear)
                .accessibilityLabel("Onboarding progress")
                .accessibilityValue("\(Int(step.progressFraction * 100)) percent")
        }
    }
}

private struct OnboardingStepIntro: View {
    let step: OnboardingWizardStep

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(step.title)
                .font(.title3.weight(.semibold))
            Text(step.subtitle)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

private struct OnboardingWizardFooter: View {
    let step: OnboardingWizardStep
    let canGoBack: Bool
    let canSkipBackend: Bool
    let goBack: () -> Void
    let skipBackend: () -> Void
    let openSettings: () -> Void
    let primaryAction: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button("Back", action: goBack)
                .disabled(!canGoBack)

            Spacer()

            if canSkipBackend {
                Button("Skip Backend Setup", action: skipBackend)
            }

            if step == .done {
                Button("Open Settings", action: openSettings)
            }

            Button(primaryTitle, action: primaryAction)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 14)
        .background(.bar)
    }

    private var primaryTitle: String {
        step == .done ? "Start Using AutoComp" : "Continue"
    }
}

private struct OnboardingShortcutRow: View {
    let command: KeyboardShortcutCommand
    let binding: KeyboardShortcutBinding

    var body: some View {
        SettingsActionRow(
            title: command.title,
            subtitle: "Current shortcut"
        ) {
            KeycapView(binding: binding)
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
            controller.startPermissionGuidance(for: kind)

        case .openSystemSettings(let kind):
            controller.startPermissionGuidance(for: kind)

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
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
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
                Text(progress.isComplete ? "Required access complete" : "Required access")
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
                .accessibilityLabel("Permission setup progress")
                .accessibilityValue("\(Int(progress.fractionComplete * 100)) percent")
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
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
            in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
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
