import AutoCompCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

@MainActor
struct ModelSettingsView: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var engine: SuggestionEngine
    @StateObject private var modelDownloadManager = ModelDownloadManager()
    @StateObject private var runtimeBootstrapModel = RuntimeBootstrapModel()
    @StateObject private var localModelSetupCoordinator = LocalModelSetupCoordinator()
    @State private var draft = CompletionBackendSettings()
    @State private var selectedRemotePreset = AutoCompCore.RemoteEndpointPreset.custom
    @State private var connectionTestState = RemoteConnectionTestState.idle
    @State private var localModelActionState: LocalModelActionState?
    @State private var localModelCatalogSearch = ""
    @State private var playgroundPrefix = "Please write "
    @State private var playgroundSuffix = ""
    @State private var playgroundResult: CompletionPlaygroundResult?
    @State private var playgroundError: String?
    @State private var isPlaygroundRunning = false
    @State private var didRunSettingsConnectionUITest = false
    @State private var didRunPlaygroundUITest = false
    @State private var debugOptions = AutoCompDebugOptions()
    @State private var backendSaveMessage: String?
    @State private var advancedMessage: String?
    @State private var remoteConsentRevision = 0
    @State private var isConfirmingRemoteConsentReset = false

    var body: some View {
        SettingsPaneForm(title: "Model") {
            activeBackendSection
            providerSection
            if showsRemoteConsentSection {
                remoteConsentSection
            }
            connectionAndRuntimeSection
            compatibilityRecommendationSection
            playgroundSection
            if draft.engineKind == .localLlama {
                localModelSection
                recommendedLocalModelsSection
            }
            advancedSection
        }
        .onAppear {
            draft = controller.completionBackendSettings
            debugOptions = controller.debugOptions()
            selectedRemotePreset = AutoCompCore.RemoteEndpointPreset.preset(forBaseURL: draft.remoteBaseURL)
            connectionTestState = .idle
            backendSaveMessage = nil
            modelDownloadManager.onModelDirectoryChanged = {
                runtimeBootstrapModel.refreshAvailableModels()
                localModelSetupCoordinator.refreshInstalledModels()
            }
            refreshLocalModels()
            runSettingsConnectionUITestIfNeeded()
            runPlaygroundUITestIfNeeded()
        }
        .confirmationDialog(
            "Reset Remote Completion Consent?",
            isPresented: $isConfirmingRemoteConsentReset,
            titleVisibility: .visible
        ) {
            Button("Reset Remote Completion Consent", role: .destructive) {
                resetRemoteCompletionConsent()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears saved remote-completion consent for the configured endpoint. You can grant consent again before sending text remotely.")
        }
    }

    @ViewBuilder
    private var activeBackendSection: some View {
        Section("Active backend") {
            let activeSettings = controller.completionBackendSettings
            SectionFooterNote(text: "Current saved provider and routing state.")
            SettingsInfoCard(
                title: activeSettings.engineKind.displayName,
                subtitle: activeBackendSubtitle(for: activeSettings),
                state: activeBackendState(for: activeSettings),
                statusTitle: activeBackendStatusTitle(for: activeSettings),
                systemImage: "bolt.horizontal.circle"
            ) {
                LabeledContent("Request destination", value: activeSettings.requestDestinationTitle)
                LabeledContent("Data leaves this Mac", value: activeSettings.dataLeavesDeviceTitle)
                LabeledContent("Remote fallback", value: activeSettings.remoteFallbackTitle)
                DisclosureGroup("Advanced backend details") {
                    LabeledContent("Stop sequences", value: activeSettings.stopSequenceSummaryTitle)
                    LabeledContent("Stop behavior", value: activeSettings.stopSequenceBehaviorTitle)
                    SectionFooterNote(text: "Detailed backend errors and last-used route diagnostics live in Developer.")
                }
            }
            Button("Reload Saved Backend") {
                reloadSavedBackend()
            }
        }
    }

    @ViewBuilder
    private var providerSection: some View {
        Section("Provider") {
            SectionFooterNote(text: "Choose one provider. Only settings needed by the selected path appear here.")
            Picker("Selected backend", selection: $draft.engineKind) {
                ForEach(CompletionEngineKind.allCases, id: \.self) { kind in
                    Text(kind.displayName).tag(kind)
                }
            }

            providerSpecificSettings

            if let warning = draft.remoteFallbackWarning {
                StatusBadge("Remote fallback", state: .warning)
                SectionFooterNote(text: warning)
            }

            DisclosureGroup("Advanced backend details") {
                LabeledContent("Stop sequences", value: draft.stopSequenceSummaryTitle)
                LabeledContent("Stop behavior", value: draft.stopSequenceBehaviorTitle)
            }

            Button("Save and Use Selected Backend") {
                saveBackend()
            }
            if let backendSaveMessage {
                StatusBadge("Saved", state: .ok)
                SectionFooterNote(text: backendSaveMessage)
            }
        }
    }

    @ViewBuilder
    private var providerSpecificSettings: some View {
        switch draft.engineKind {
        case .remote:
            SettingsActionRow(
                title: "Remote OpenAI-compatible",
                subtitle: "Sends completion requests to the endpoint below.",
                state: remoteProviderState,
                statusTitle: remoteProviderStatusTitle
            )
            remoteProviderFields
        case .localLlama:
            let diagnostic = draft.localDiagnostic()
            SettingsActionRow(
                title: "Local Llama",
                subtitle: diagnostic.modelFileTitle,
                state: diagnostic.isUsable ? .ok : .warning,
                statusTitle: diagnostic.isUsable ? "Ready" : "Needs setup"
            )
            LabeledContent("Request destination", value: draft.requestDestinationTitle)
            LabeledContent("Data leaves this Mac", value: draft.dataLeavesDeviceTitle)
            Toggle("Fallback to remote if local fails", isOn: $draft.fallbackToRemoteOnLocalFailure)
            if draft.fallbackToRemoteOnLocalFailure {
                SectionFooterNote(text: "Remote fallback is enabled: if local completion fails, autocomplete text may be sent after explicit consent below.")
                DisclosureGroup("Remote fallback provider") {
                    remoteProviderFields
                }
            }
        case .appleIntelligence:
            let diagnostic = draft.appleIntelligenceDiagnostic()
            SettingsActionRow(
                title: "Apple Intelligence",
                subtitle: diagnostic.requirementTitle,
                state: diagnostic.isUsable ? .ok : .warning,
                statusTitle: diagnostic.availabilityTitle
            )
            LabeledContent("Request destination", value: draft.requestDestinationTitle)
            LabeledContent("Data leaves this Mac", value: draft.dataLeavesDeviceTitle)
            Toggle("Fallback to remote if Apple fails", isOn: $draft.fallbackToRemoteOnAppleIntelligenceFailure)
            SectionFooterNote(text: "Apple Intelligence fallback uses the remote backend settings above.")
            if draft.fallbackToRemoteOnAppleIntelligenceFailure {
                DisclosureGroup("Remote fallback provider") {
                    remoteProviderFields
                }
            }
        }
    }

    @ViewBuilder
    private var remoteProviderFields: some View {
        Picker("Endpoint preset", selection: $selectedRemotePreset) {
            ForEach(AutoCompCore.RemoteEndpointPreset.allCases) { preset in
                Text(preset.title).tag(preset)
            }
        }
        .onChange(of: selectedRemotePreset) { _, preset in
            guard let baseURL = preset.defaultBaseURL else {
                return
            }
            draft.remoteBaseURL = baseURL
        }
        TextField("Base URL", text: $draft.remoteBaseURL)
            .onChange(of: draft.remoteBaseURL) { _, baseURL in
                selectedRemotePreset = AutoCompCore.RemoteEndpointPreset.preset(forBaseURL: baseURL)
            }
        SecureField("API key", text: $draft.remoteAPIKey)
        TextField("Model", text: $draft.remoteModel)
        LabeledContent("Endpoint type", value: draft.remoteConsentEndpointKindTitle)
    }

    @ViewBuilder
    private var remoteConsentSection: some View {
        Section("Remote completion consent") {
            let requirements = draft.remoteConsentRequirements
            SectionFooterNote(text: "Consent is saved per endpoint before autocomplete text can leave this Mac.")
            LabeledContent("Remote endpoint", value: draft.remoteBaseURL)
            LabeledContent("Endpoint type", value: draft.remoteConsentEndpointKindTitle)

            ForEach(requirements) { requirement in
                let hasConsent = controller.hasRemoteCompletionConsent(
                    for: requirement.scope,
                    settings: draft
                )
                SettingsInfoCard(
                    title: requirement.title,
                    subtitle: requirement.detail,
                    state: hasConsent ? .ok : .warning,
                    statusTitle: hasConsent ? "Allowed" : "Needs consent",
                    systemImage: "lock.shield"
                ) {
                    if hasConsent {
                        SectionFooterNote(text: "Consent is saved for this endpoint.")
                    } else {
                        Button(requirement.buttonTitle) {
                            controller.grantRemoteCompletionConsent(
                                for: requirement.scope,
                                settings: draft
                            )
                            remoteConsentRevision += 1
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var connectionAndRuntimeSection: some View {
        Section("Connection and runtime test") {
            SectionFooterNote(text: "Run the check for the active remote path, or review local provider readiness.")
            if showsRemoteProviderSettings {
                HStack {
                    Button(remoteConnectionActionTitle) {
                        testRemoteConnection()
                    }
                    .accessibilityLabel("Test Connection")
                    .disabled(connectionTestState.isTesting)

                    if connectionTestState.isTesting {
                        ProgressView()
                            .controlSize(.small)
                    }
                }
                connectionStatusView
            } else {
                SectionFooterNote(text: draft.remoteConsentLocalOnlyDescription)
            }

            if draft.engineKind == .localLlama {
                localRuntimeStatusCard
            }

            if draft.engineKind == .appleIntelligence {
                appleRuntimeStatusCard
            }
        }
    }

    @ViewBuilder
    private var localRuntimeStatusCard: some View {
        let diagnostic = draft.localDiagnostic()
        SettingsInfoCard(
            title: "Local runtime",
            subtitle: diagnostic.modelFileTitle,
            state: diagnostic.isUsable ? .ok : .warning,
            statusTitle: diagnostic.isUsable ? "Ready" : "Needs setup",
            systemImage: "internaldrive"
        ) {
            LabeledContent("Runtime", value: diagnostic.runtimeTitle)
            LabeledContent("Fallback", value: diagnostic.fallbackTitle)
            DisclosureGroup("Technical details") {
                LabeledContent("Load state", value: diagnostic.loadStateTitle)
                LabeledContent("Last error", value: diagnostic.lastErrorTitle)
                LabeledContent("Memory limit", value: diagnostic.memoryLimitTitle)
                SectionFooterNote(text: "Developer shows detailed runtime diagnostics and last backend errors.")
            }
        }
    }

    @ViewBuilder
    private var appleRuntimeStatusCard: some View {
        let diagnostic = draft.appleIntelligenceDiagnostic()
        SettingsInfoCard(
            title: "Apple Intelligence",
            subtitle: diagnostic.requirementTitle,
            state: diagnostic.isUsable ? .ok : .warning,
            statusTitle: diagnostic.availabilityTitle,
            systemImage: "apple.logo"
        ) {
            LabeledContent("Fallback", value: diagnostic.fallbackTitle)
            DisclosureGroup("Technical details") {
                SectionFooterNote(text: "Apple Intelligence requires FoundationModels in the build SDK and a supported macOS release.")
            }
        }
    }

    @ViewBuilder
    private var compatibilityRecommendationSection: some View {
        Section("Compatibility recommendation") {
            let recommendation = ModelCompatibilityMatrix.bundled.recommendation(for: draft)
            SectionFooterNote(text: "Matrix guidance for request mode, multiple completions, and expected latency.")
            SettingsInfoCard(
                title: recommendation.rowTitle,
                subtitle: recommendation.fimTitle,
                state: compatibilityState(for: recommendation),
                statusTitle: compatibilityStatusTitle(for: recommendation),
                systemImage: "checklist"
            ) {
                LabeledContent("FIM behavior", value: recommendation.fimTitle)
                LabeledContent("Multiple completions", value: recommendation.multipleCompletionsTitle)
                LabeledContent("Latency", value: recommendation.latencyTitle)
                LabeledContent("Evidence", value: recommendation.evidenceTitle)
                DisclosureGroup("Evidence details") {
                    SectionFooterNote(text: recommendation.detail)
                }
            }
        }
    }

    @ViewBuilder
    private var playgroundSection: some View {
        Section("Playground") {
            SectionFooterNote(text: "Test the draft provider without changing the saved backend.")
            Text("Prefix")
                .font(.caption.weight(.medium))
            PlaygroundTextView(text: $playgroundPrefix, onTab: acceptPlaygroundSuggestion)
                .frame(minHeight: 90)

            TextField("Suffix after cursor", text: $playgroundSuffix)

            HStack {
                Button("Run Playground") {
                    runPlaygroundCompletion()
                }
                .disabled(isPlaygroundRunning)

                Button("Accept Result") {
                    _ = acceptPlaygroundSuggestion()
                }
                .disabled(playgroundResult?.normalizedOutput.isEmpty != false)

                if isPlaygroundRunning {
                    ProgressView()
                        .controlSize(.small)
                }
            }

            let preview = controller.playgroundPreview(
                prefix: playgroundPrefix,
                suffix: playgroundSuffix,
                settings: draft
            )
            LabeledContent("Mode", value: preview.modeTitle)
            LabeledContent("Request destination", value: preview.requestDestinationTitle)
            LabeledContent("Data leaves this Mac", value: preview.dataLeavesDeviceTitle)
            LabeledContent("Remote fallback", value: preview.remoteFallbackTitle)
            DisclosureGroup("Request preview") {
                if let promptPreview = preview.promptPreview(options: debugOptions) {
                    Text("Prompt preview")
                        .font(.caption.weight(.medium))
                    Text(promptPreview)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    SectionFooterNote(text: "Prompt preview hidden until local debug opt-in is enabled in Developer.")
                }
            }

            if let playgroundResult {
                SettingsInfoCard(
                    title: "Playground result",
                    subtitle: "Normalized output is ready to accept.",
                    state: .ok,
                    statusTitle: "\(playgroundResult.latencyMs) ms",
                    systemImage: "play.circle"
                ) {
                    LabeledContent("Latency", value: "\(playgroundResult.latencyMs) ms")
                    Text("Normalized output")
                        .font(.caption.weight(.medium))
                    Text(playgroundResult.normalizedOutput)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.green)
                        .textSelection(.enabled)
                    DisclosureGroup("Output details") {
                        Text("Raw output")
                            .font(.caption.weight(.medium))
                        Text(playgroundResult.rawOutput)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
            }

            if let playgroundError {
                SettingsInfoCard(
                    title: "Playground failed",
                    subtitle: "Review the technical error before changing provider settings.",
                    state: .error,
                    statusTitle: "Failed",
                    systemImage: "xmark.octagon"
                ) {
                    DisclosureGroup("Technical error") {
                        SectionFooterNote(text: playgroundError)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var localModelSection: some View {
        Section("Local model") {
            SectionFooterNote(text: "Choose a GGUF model for Local Llama.")
            SettingsActionRow(
                title: "Setup status",
                subtitle: localModelSetupCoordinator.state.statusText,
                state: localModelSetupVisualState,
                statusTitle: localModelSetupStatusTitle
            )
            if runtimeBootstrapModel.availableModels.isEmpty {
                SectionFooterNote(text: "No local GGUF models found in \(modelDownloadManager.modelsDirectoryPath).")
            } else {
                Picker("Installed model", selection: localModelSelectionBinding) {
                    Text("Choose a model").tag("")
                    ForEach(runtimeBootstrapModel.availableModels) { model in
                        Text("\(model.displayName) (\(model.sizeLabel))").tag(model.url.path)
                    }
                }
            }

            TextField("Model path", text: $draft.localModelPath)
            TextField("Max RAM bytes", text: localMaxRAMBinding)

            HStack {
                Button("Import GGUF") {
                    chooseLocalGGUF()
                }
                Button("Open Models Folder") {
                    openModelsDirectory()
                }
                Button("Refresh") {
                    refreshLocalModels()
                }
                Button("Clean Partial Downloads") {
                    cleanPartialDownloads()
                }
                Button("Remove Selected Model", role: .destructive) {
                    removeSelectedLocalModel()
                }
                .disabled(selectedInstalledLocalModel == nil)
            }

            if let localModelActionState {
                StatusBadge(localModelActionState.message, state: localModelActionState.visualState)
            }
        }
    }

    @ViewBuilder
    private var recommendedLocalModelsSection: some View {
        Section("Recommended local models") {
            SectionFooterNote(text: "Optional downloads for the local provider.")
            TextField("Search catalog", text: $localModelCatalogSearch)
            ForEach(filteredRecommendedLocalModels) { model in
                recommendedModelRow(model)
            }
        }
    }

    @ViewBuilder
    private var advancedSection: some View {
        Section("Advanced") {
            SectionFooterNote(text: "Operational actions for provider recovery and debug handoff.")
            DangerZoneView(
                title: "Provider recovery",
                message: "Use these only when a provider is stuck or consent must be re-granted."
            ) {
                HStack {
                    Button("Unload Local Runtime") {
                        controller.unloadLocalLlamaRuntime()
                        advancedMessage = "Local runtime unload requested."
                    }
                    .disabled(controller.completionBackendSettings.engineKind != .localLlama)
                    Button("Reset Remote Completion Consent", role: .destructive) {
                        isConfirmingRemoteConsentReset = true
                    }
                }
            }
            HStack {
                Button("Export Debug Logs...") {
                    exportDebugLogs()
                }
                Button("Open Developer Diagnostics") {
                    controller.selectedSettingsSection = .developer
                }
            }
            if debugOptions.localDebugOptIn || draft.multiSuggestionEnabled {
                Toggle("Enable multi-suggestion popup", isOn: $draft.multiSuggestionEnabled)
                SectionFooterNote(text: "Internal/debug only. Keep disabled for beta QA unless this run explicitly validates multi-suggestion behavior.")
            }
            SectionFooterNote(text: "Autocomplete text may be sent to the request destination above, and to the remote backend only when remote fallback is enabled after a local or Apple failure.")
            if let advancedMessage {
                StatusBadge(advancedMessage, state: messageVisualState(advancedMessage))
            }
        }
    }

    private func saveBackend() {
        controller.saveCompletionBackendSettings(draft)
        draft = controller.completionBackendSettings
        selectedRemotePreset = AutoCompCore.RemoteEndpointPreset.preset(forBaseURL: draft.remoteBaseURL)
        backendSaveMessage = savedBackendMessage(for: draft)
    }

    private func reloadSavedBackend() {
        controller.refreshCompletionBackendSettings()
        draft = controller.completionBackendSettings
        selectedRemotePreset = AutoCompCore.RemoteEndpointPreset.preset(forBaseURL: draft.remoteBaseURL)
        connectionTestState = .idle
        backendSaveMessage = nil
    }

    private func savedBackendMessage(for settings: CompletionBackendSettings) -> String {
        switch settings.engineKind {
        case .remote:
            return "Saved Remote OpenAI-compatible: \(settings.remoteModel) at \(settings.remoteBaseURL)."
        case .localLlama:
            return "Saved Local Llama as the selected backend."
        case .appleIntelligence:
            return "Saved Apple Intelligence as the selected backend."
        }
    }

    private var showsRemoteProviderSettings: Bool {
        switch draft.engineKind {
        case .remote:
            return true
        case .localLlama:
            return draft.fallbackToRemoteOnLocalFailure
        case .appleIntelligence:
            return draft.fallbackToRemoteOnAppleIntelligenceFailure
        }
    }

    private var showsRemoteConsentSection: Bool {
        !draft.remoteConsentRequirements.isEmpty
    }

    private var remoteProviderState: SettingsVisualState {
        isRemoteProviderConfigured(draft) ? .ok : .warning
    }

    private var remoteProviderStatusTitle: String {
        isRemoteProviderConfigured(draft) ? "Configured" : "Needs setup"
    }

    private var remoteConnectionActionTitle: String {
        draft.engineKind == .remote ? "Test Connection" : "Test Remote Fallback"
    }

    private func isRemoteProviderConfigured(_ settings: CompletionBackendSettings) -> Bool {
        !settings.remoteBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !settings.remoteModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func activeBackendSubtitle(for settings: CompletionBackendSettings) -> String {
        switch settings.engineKind {
        case .remote where !isRemoteProviderConfigured(settings):
            return "Complete the remote URL and model before using this provider."
        case .remote:
            return settings.requestDestinationTitle
        case .localLlama:
            let diagnostic = settings.localDiagnostic()
            return diagnostic.isUsable ? settings.requestDestinationTitle : diagnostic.modelFileTitle
        case .appleIntelligence:
            let diagnostic = settings.appleIntelligenceDiagnostic()
            return diagnostic.isUsable ? settings.requestDestinationTitle : diagnostic.requirementTitle
        }
    }

    private func activeBackendState(for settings: CompletionBackendSettings) -> SettingsVisualState {
        switch settings.engineKind {
        case .remote:
            guard isRemoteProviderConfigured(settings) else {
                return .warning
            }
            return SettingsVisualState.backend(engine.backendStatusSummary.state)
        case .localLlama:
            return settings.localDiagnostic().isUsable ? .ok : .warning
        case .appleIntelligence:
            return settings.appleIntelligenceDiagnostic().isUsable ? .ok : .warning
        }
    }

    private func activeBackendStatusTitle(for settings: CompletionBackendSettings) -> String {
        switch settings.engineKind {
        case .remote:
            guard isRemoteProviderConfigured(settings) else {
                return "Not configured"
            }
            switch engine.backendStatusSummary.state {
            case .connected:
                return "Ready"
            case .disconnected:
                return "Failed"
            case .paused:
                return "Paused"
            }
        case .localLlama:
            if settings.localDiagnostic().isUsable {
                return "Ready"
            }
            return settings.fallbackToRemoteOnLocalFailure ? "Fallback" : "Not configured"
        case .appleIntelligence:
            if settings.appleIntelligenceDiagnostic().isUsable {
                return "Ready"
            }
            return settings.fallbackToRemoteOnAppleIntelligenceFailure ? "Fallback" : "Not configured"
        }
    }

    private func compatibilityState(for recommendation: ModelCompatibilityRecommendation) -> SettingsVisualState {
        guard let row = recommendation.row else {
            return .warning
        }
        switch row.fimSupport {
        case .supported:
            return .ok
        case .unsupported:
            return .warning
        case .unknown, .skipped:
            return .pending
        }
    }

    private func compatibilityStatusTitle(for recommendation: ModelCompatibilityRecommendation) -> String {
        guard let row = recommendation.row else {
            return "No row"
        }
        switch row.fimSupport {
        case .supported:
            return "Supported"
        case .unsupported:
            return "Limited"
        case .unknown, .skipped:
            return "Unknown"
        }
    }

    @ViewBuilder
    private var connectionStatusView: some View {
        switch connectionTestState {
        case .idle, .testing:
            EmptyView()
        case .connected(let message):
            SettingsInfoCard(
                title: "Remote connection",
                subtitle: "Remote backend is reachable.",
                state: .ok,
                statusTitle: "Connected",
                systemImage: "network"
            ) {
                DisclosureGroup("Response details") {
                    SectionFooterNote(text: message)
                }
            }
        case .failed(let message):
            SettingsInfoCard(
                title: "Remote connection",
                subtitle: "Connection failed.",
                state: .error,
                statusTitle: "Failed",
                systemImage: "network.slash"
            ) {
                DisclosureGroup("Technical error") {
                    SectionFooterNote(text: message)
                }
            }
        }
    }

    private func messageVisualState(_ message: String) -> SettingsVisualState {
        message.localizedCaseInsensitiveContains("unable") ? .error : .ok
    }

    private func resetRemoteCompletionConsent() {
        controller.resetRemoteCompletionConsent()
        remoteConsentRevision += 1
        advancedMessage = "Remote completion consent reset."
    }

    private func exportDebugLogs() {
        controller.withInteractionPipelineSuspended(reason: .settingsExport) {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Export"
            panel.message = "Choose where to save the local debug log export."

            let response = controller.withInteractionPipelineSuspended(reason: .openPanel) {
                panel.runModal()
            }
            guard response == .OK, let directory = panel.url else {
                return
            }

            do {
                let exportURL = try controller.exportDebugLogs(to: directory)
                advancedMessage = "Debug logs exported to \(exportURL.path)."
            } catch {
                advancedMessage = "Unable to export debug logs: \(error.localizedDescription)"
            }
        }
    }

    private var localMaxRAMBinding: Binding<String> {
        Binding {
            String(draft.localMaxRAMBytes)
        } set: { value in
            let digits = value.filter(\.isNumber)
            if let bytes = UInt64(digits) {
                draft.localMaxRAMBytes = bytes
            }
        }
    }

    private var localModelSelectionBinding: Binding<String> {
        Binding {
            runtimeBootstrapModel.selectedModel(for: draft.localModelPath)?.url.path ?? ""
        } set: { path in
            guard !path.isEmpty,
                  let url = runtimeBootstrapModel.availableModels.first(where: { $0.url.path == path })?.url else {
                return
            }
            useInstalledLocalModel(url)
        }
    }

    private var selectedInstalledLocalModel: LocalModelOption? {
        runtimeBootstrapModel.selectedModel(for: draft.localModelPath)
    }

    private var filteredRecommendedLocalModels: [DownloadableLocalModel] {
        let query = localModelCatalogSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            return modelDownloadManager.models
        }
        return modelDownloadManager.models.filter {
            $0.displayName.localizedCaseInsensitiveContains(query)
                || $0.filename.localizedCaseInsensitiveContains(query)
        }
    }

    private func testRemoteConnection() {
        connectionTestState = .testing
        Task { @MainActor in
            let result = await controller.testRemoteConnection(settings: draft)
            if draft.remoteModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let suggestedModel = result.suggestedModel {
                draft.remoteModel = suggestedModel
            }
            connectionTestState = RemoteConnectionTestState(result)
        }
    }

    private func runSettingsConnectionUITestIfNeeded() {
        guard controller.shouldRunSettingsConnectionUITest,
              !didRunSettingsConnectionUITest else {
            return
        }

        didRunSettingsConnectionUITest = true
        draft = controller.settingsConnectionUITestBackendSettings
        selectedRemotePreset = AutoCompCore.RemoteEndpointPreset.preset(forBaseURL: draft.remoteBaseURL)
        connectionTestState = .idle
        testRemoteConnection()
    }

    private func runPlaygroundCompletion() {
        isPlaygroundRunning = true
        playgroundError = nil
        Task { @MainActor in
            do {
                playgroundResult = try await controller.completePlayground(
                    prefix: playgroundPrefix,
                    suffix: playgroundSuffix,
                    settings: draft
                )
            } catch {
                playgroundResult = nil
                playgroundError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isPlaygroundRunning = false
        }
    }

    @discardableResult
    private func acceptPlaygroundSuggestion() -> Bool {
        guard let normalizedOutput = playgroundResult?.normalizedOutput,
              !normalizedOutput.isEmpty else {
            return false
        }

        playgroundPrefix += normalizedOutput
        playgroundResult = nil
        playgroundError = nil
        return true
    }

    private func runPlaygroundUITestIfNeeded() {
        guard controller.isPlaygroundUITestMode,
              !didRunPlaygroundUITest else {
            return
        }

        didRunPlaygroundUITest = true
        playgroundPrefix = "Playground prefix "
        playgroundSuffix = " after suffix."
        runPlaygroundCompletion()
    }

    @ViewBuilder
    private func recommendedModelRow(_ model: DownloadableLocalModel) -> some View {
        let state = modelDownloadManager.state(for: model)

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.displayName)
                    .font(.headline)
                Spacer()
                Text(model.approximateSizeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(model.filename)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack {
                StatusBadge(state.statusText, state: SettingsVisualState.modelDownload(state))
                Spacer()
                recommendedModelAction(model, state: state)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func recommendedModelAction(
        _ model: DownloadableLocalModel,
        state: ModelDownloadState
    ) -> some View {
        switch state {
        case .loading(let progress):
            if let progress {
                ProgressView(value: progress)
                    .frame(width: 72)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            Button("Cancel") {
                modelDownloadManager.cancel(filename: model.filename)
            }
        case .ready:
            Button("Use") {
                if let url = modelDownloadManager.installedModelURL(for: model) {
                    useInstalledLocalModel(url)
                }
            }
        case .failed:
            HStack {
                Button("Retry Download") {
                    modelDownloadManager.clearFailedState(filename: model.filename)
                    startModelDownload(model)
                }
                Button("Clear") {
                    modelDownloadManager.clearFailedState(filename: model.filename)
                    localModelSetupCoordinator.beginCatalogBrowsing()
                }
            }
        case .idle:
            Button("Download") {
                startModelDownload(model)
            }
        }
    }

    private var localModelSetupVisualState: SettingsVisualState {
        switch localModelSetupCoordinator.state {
        case .idle, .browsingCatalog:
            return .pending
        case .downloading, .validating, .importing:
            return .pending
        case .ready:
            return .ok
        case .failed:
            return .error
        }
    }

    private var localModelSetupStatusTitle: String {
        switch localModelSetupCoordinator.state {
        case .idle:
            return "Idle"
        case .browsingCatalog:
            return "Catalog"
        case .downloading:
            return "Downloading"
        case .validating:
            return "Validating"
        case .importing:
            return "Importing"
        case .ready:
            return "Ready"
        case .failed:
            return "Failed"
        }
    }

    private func startModelDownload(_ model: DownloadableLocalModel) {
        localModelSetupCoordinator.beginCatalogBrowsing()
        localModelSetupCoordinator.updateDownloadState(.loading(progress: nil), filename: model.filename)
        modelDownloadManager.download(model)
    }

    private func chooseLocalGGUF() {
        controller.withInteractionPipelineSuspended(reason: .modelImport) {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            if let ggufType = UTType(filenameExtension: "gguf") {
                panel.allowedContentTypes = [ggufType]
            }

            let response = controller.withInteractionPipelineSuspended(reason: .openPanel) {
                panel.runModal()
            }
            guard response == .OK,
                  let url = panel.url else {
                return
            }

            useLocalModel(url)
        }
    }

    private func useLocalModel(_ url: URL) {
        controller.withInteractionPipelineSuspended(reason: .modelImport) {
            do {
                let option = try localModelSetupCoordinator.importLocalModel(from: url)
                saveLocalModelSelection(option.url, message: "Imported \(option.filename)")
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                draft.localLastError = message
                localModelActionState = .failed(message)
            }
        }
    }

    private func useInstalledLocalModel(_ url: URL) {
        controller.withInteractionPipelineSuspended(reason: .modelImport) {
            do {
                let option = try localModelSetupCoordinator.selectInstalledModel(at: url)
                saveLocalModelSelection(option.url, message: "Using \(option.filename)")
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                draft.localLastError = message
                localModelActionState = .failed(message)
            }
        }
    }

    private func saveLocalModelSelection(_ url: URL, message: String) {
        var updatedDraft = draft
        updatedDraft.engineKind = .localLlama
        updatedDraft.localModelPath = url.path
        updatedDraft.localLastError = nil
        draft = updatedDraft
        controller.saveCompletionBackendSettings(updatedDraft)
        refreshLocalModels()
        localModelActionState = .ready(message)
        backendSaveMessage = savedBackendMessage(for: updatedDraft)
    }

    private func removeSelectedLocalModel() {
        guard let selectedInstalledLocalModel else {
            return
        }

        controller.withInteractionPipelineSuspended(reason: .modelImport) {
            do {
                try localModelSetupCoordinator.removeInstalledModel(selectedInstalledLocalModel)
                if draft.localModelPath == selectedInstalledLocalModel.url.path {
                    var updatedDraft = draft
                    updatedDraft.localModelPath = ""
                    updatedDraft.localLastError = nil
                    draft = updatedDraft
                    controller.saveCompletionBackendSettings(updatedDraft)
                }
                refreshLocalModels()
                localModelActionState = .ready("Removed \(selectedInstalledLocalModel.filename)")
            } catch {
                let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                localModelActionState = .failed(message)
            }
        }
    }

    private func cleanPartialDownloads() {
        let removedCount = modelDownloadManager.removePartialDownloads()
        refreshLocalModels()
        localModelActionState = .ready(
            removedCount == 1
                ? "Removed 1 partial download."
                : "Removed \(removedCount) partial downloads."
        )
    }

    private func openModelsDirectory() {
        do {
            try FileManager.default.createDirectory(
                at: modelDownloadManager.modelsDirectory,
                withIntermediateDirectories: true
            )
            NSWorkspace.shared.open(modelDownloadManager.modelsDirectory)
        } catch {
            localModelActionState = .failed(error.localizedDescription)
        }
    }

    private func refreshLocalModels() {
        runtimeBootstrapModel.refreshAvailableModels()
        localModelSetupCoordinator.refreshInstalledModels()
        modelDownloadManager.refreshModelStates()
    }
}


private enum RemoteConnectionTestState: Equatable {
    case idle
    case testing
    case connected(String)
    case failed(String)

    init(_ result: RemoteBackendProbeResult) {
        switch result.status {
        case .connected:
            self = .connected(result.message)
        case .failed:
            self = .failed(result.message)
        }
    }

    var isTesting: Bool {
        self == .testing
    }
}

private enum LocalModelActionState: Equatable {
    case ready(String)
    case failed(String)

    var message: String {
        switch self {
        case .ready(let message),
             .failed(let message):
            return message
        }
    }

    var visualState: SettingsVisualState {
        switch self {
        case .ready:
            return .ok
        case .failed:
            return .error
        }
    }
}

private struct PlaygroundTextView: NSViewRepresentable {
    @Binding var text: String
    let onTab: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let textView = PlaygroundNSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.onTab = onTab
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.string = text

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? PlaygroundNSTextView else {
            return
        }
        textView.onTab = onTab
        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }
            text = textView.string
        }
    }
}

private final class PlaygroundNSTextView: NSTextView {
    var onTab: (() -> Bool)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == CapturedInputEventAdapter.tabKeyCode,
           onTab?() == true {
            return
        }
        super.keyDown(with: event)
    }
}
