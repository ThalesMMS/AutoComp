import AutoCompCore
import Foundation

struct BackendSurface: Equatable {
    let engineKind: CompletionEngineKind
    let requestDestinationTitle: String
    let dataLeavesDeviceTitle: String
    let remoteFallbackTitle: String
    let remoteFallbackWarning: String?
    let summary: String
    let savedBackendMessage: String
    let privacySummary: String
    let privacyStatusTitle: String
    let exposesAutocompleteTextRemotely: Bool
    let isRemoteProviderConfigured: Bool
    let localRuntimeDiagnostic: LocalLlamaDiagnostic
    let localDiagnostic: LocalLlamaDiagnostic?
    let appleIntelligenceAvailabilityDiagnostic: AppleIntelligenceDiagnostic
    let appleIntelligenceDiagnostic: AppleIntelligenceDiagnostic?
    let diagnosticsLastBackendTitle: String?
    private let diagnosticsLocalErrorTitle: String?
    private let diagnosticsAppleErrorTitle: String?
    private let diagnosticsRemoteErrorTitle: String?
    private let remoteBaseURL: String
    private let fallbackToRemoteOnLocalFailure: Bool
    private let fallbackToRemoteOnAppleIntelligenceFailure: Bool

    init(
        settings: CompletionBackendSettings,
        fileExists: (String) -> Bool = FileManager.default.fileExists(atPath:),
        localLoadStatus: LocalLlamaRuntimeStatus = .unloaded,
        appleAvailability: AppleFoundationModelAvailability = SystemAppleFoundationModelBackend.availability(),
        diagnostics: SuggestionDiagnostics? = nil
    ) {
        engineKind = settings.engineKind
        remoteBaseURL = settings.remoteBaseURL
        fallbackToRemoteOnLocalFailure = settings.fallbackToRemoteOnLocalFailure
        fallbackToRemoteOnAppleIntelligenceFailure = settings.fallbackToRemoteOnAppleIntelligenceFailure
        isRemoteProviderConfigured = Self.isRemoteProviderConfigured(settings)

        let localRuntimeDiagnostic = Self.localRuntimeDiagnostic(
            settings: settings,
            fileExists: fileExists,
            loadStatus: localLoadStatus
        )
        let appleDiagnostic = Self.appleIntelligenceDiagnostic(
            settings: settings,
            availability: appleAvailability
        )
        self.localRuntimeDiagnostic = localRuntimeDiagnostic
        self.localDiagnostic = settings.engineKind == .localLlama ? localRuntimeDiagnostic : nil
        self.appleIntelligenceAvailabilityDiagnostic = appleDiagnostic
        self.appleIntelligenceDiagnostic = settings.engineKind == .appleIntelligence ? appleDiagnostic : nil

        requestDestinationTitle = Self.requestDestinationTitle(
            settings: settings
        )
        dataLeavesDeviceTitle = Self.dataLeavesDeviceTitle(
            settings: settings,
            localDiagnostic: localRuntimeDiagnostic,
            appleDiagnostic: appleDiagnostic
        )
        remoteFallbackTitle = Self.remoteFallbackTitle(settings)
        remoteFallbackWarning = Self.remoteFallbackWarning(settings)
        summary = Self.backendSummary(
            settings: settings,
            localDiagnostic: localRuntimeDiagnostic,
            appleDiagnostic: appleDiagnostic
        )
        savedBackendMessage = Self.savedBackendMessage(settings)
        privacySummary = Self.privacySummary(settings)
        privacyStatusTitle = Self.privacyStatusTitle(settings)
        exposesAutocompleteTextRemotely = Self.exposesAutocompleteTextRemotely(settings)
        diagnosticsLastBackendTitle = diagnostics?.backend.lastUsedTitle
        diagnosticsLocalErrorTitle = diagnostics?.backend.errorTitle(for: .localLlama)
        diagnosticsAppleErrorTitle = diagnostics?.backend.errorTitle(for: .appleIntelligence)
        diagnosticsRemoteErrorTitle = diagnostics?.backend.errorTitle(for: .remote)
    }

    func remoteBackendExposureTitle(sourceEnabled: Bool) -> String {
        guard sourceEnabled else {
            return "No; source is off."
        }

        switch engineKind {
        case .remote:
            return "Yes, sent to \(remoteBaseURL)."
        case .localLlama:
            return fallbackToRemoteOnLocalFailure
                ? "Only after local failure fallback to \(remoteBaseURL)."
                : "No remote backend."
        case .appleIntelligence:
            return fallbackToRemoteOnAppleIntelligenceFailure
                ? "Only after Apple Intelligence fallback to \(remoteBaseURL)."
                : "No remote backend."
        }
    }

    func activeBackendSubtitle(remoteProviderConfigured: Bool) -> String {
        switch engineKind {
        case .remote where !remoteProviderConfigured:
            return "Complete the remote URL and model before using this provider."
        case .remote:
            return requestDestinationTitle
        case .localLlama:
            return localRuntimeDiagnostic.isUsable ? requestDestinationTitle : localRuntimeDiagnostic.modelFileTitle
        case .appleIntelligence:
            return appleIntelligenceAvailabilityDiagnostic.isUsable
                ? requestDestinationTitle
                : appleIntelligenceAvailabilityDiagnostic.requirementTitle
        }
    }

    func activeBackendStatusTitle(
        remoteProviderConfigured: Bool,
        remoteStatus: BackendStatusSummary
    ) -> String {
        switch engineKind {
        case .remote:
            guard remoteProviderConfigured else {
                return "Not configured"
            }
            switch remoteStatus.state {
            case .connected:
                return "Ready"
            case .disconnected:
                return "Failed"
            case .paused:
                return "Paused"
            }
        case .localLlama:
            if localRuntimeDiagnostic.isUsable {
                return "Ready"
            }
            return fallbackToRemoteOnLocalFailure ? "Fallback" : "Not configured"
        case .appleIntelligence:
            if appleIntelligenceAvailabilityDiagnostic.isUsable {
                return "Ready"
            }
            return fallbackToRemoteOnAppleIntelligenceFailure ? "Fallback" : "Not configured"
        }
    }

    func diagnosticsErrorTitle(for kind: CompletionEngineKind) -> String? {
        switch kind {
        case .remote:
            return diagnosticsRemoteErrorTitle
        case .localLlama:
            return diagnosticsLocalErrorTitle
        case .appleIntelligence:
            return diagnosticsAppleErrorTitle
        }
    }

    private static func backendSummary(
        settings: CompletionBackendSettings,
        localDiagnostic: LocalLlamaDiagnostic,
        appleDiagnostic: AppleIntelligenceDiagnostic
    ) -> String {
        switch settings.engineKind {
        case .remote:
            return "Remote backend: \(settings.remoteModel) at \(settings.remoteBaseURL)"
        case .localLlama:
            if localDiagnostic.isUsable {
                return settings.fallbackToRemoteOnLocalFailure
                    ? "Local Llama backend available with remote fallback at \(settings.localModelPath)"
                    : "Local Llama backend available without fallback at \(settings.localModelPath)"
            }
            return settings.fallbackToRemoteOnLocalFailure
                ? "Local Llama backend unavailable: \(localDiagnostic.runtimeTitle); \(localDiagnostic.modelFileTitle); remote fallback enabled"
                : "Local Llama backend unavailable: \(localDiagnostic.runtimeTitle); \(localDiagnostic.modelFileTitle); remote fallback disabled"
        case .appleIntelligence:
            if appleDiagnostic.isUsable {
                return settings.fallbackToRemoteOnAppleIntelligenceFailure
                    ? "Apple Intelligence backend available with remote fallback"
                    : "Apple Intelligence backend available without fallback"
            }
            return settings.fallbackToRemoteOnAppleIntelligenceFailure
                ? "Apple Intelligence backend unavailable: \(appleDiagnostic.requirementTitle); remote fallback enabled"
                : "Apple Intelligence backend unavailable: \(appleDiagnostic.requirementTitle); remote fallback disabled"
        }
    }

    private static func requestDestinationTitle(settings: CompletionBackendSettings) -> String {
        switch settings.engineKind {
        case .remote:
            return "Remote: \(settings.remoteModel) at \(settings.remoteBaseURL)"
        case .localLlama:
            guard !settings.localModelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return "Local in-process: no model selected"
            }
            let modelFileName = URL(fileURLWithPath: settings.localModelPath).lastPathComponent
            return "Local in-process: \(modelFileName.isEmpty ? settings.localConfiguration.modelName : modelFileName)"
        case .appleIntelligence:
            return "Apple Intelligence on this Mac"
        }
    }

    private static func dataLeavesDeviceTitle(
        settings: CompletionBackendSettings,
        localDiagnostic: LocalLlamaDiagnostic,
        appleDiagnostic: AppleIntelligenceDiagnostic
    ) -> String {
        switch settings.engineKind {
        case .remote:
            return "Yes, autocomplete text is sent to \(settings.remoteBaseURL)."
        case .localLlama:
            if settings.fallbackToRemoteOnLocalFailure {
                return "Local first; text may be sent to \(settings.remoteBaseURL) after a local failure."
            }
            return localDiagnostic.isUsable
                ? "No, local completion requests stay on this Mac."
                : "No remote endpoint; local completion is blocked until runtime and model prerequisites are met."
        case .appleIntelligence:
            if settings.fallbackToRemoteOnAppleIntelligenceFailure {
                return "Apple first; text may be sent to \(settings.remoteBaseURL) after an Apple Intelligence failure."
            }
            return appleDiagnostic.isUsable
                ? "No remote endpoint while Apple Intelligence succeeds."
                : "No remote endpoint; Apple Intelligence is unavailable on this Mac."
        }
    }

    private static func remoteFallbackTitle(_ settings: CompletionBackendSettings) -> String {
        switch settings.engineKind {
        case .remote:
            return "Not applicable because the remote backend is selected."
        case .localLlama:
            return settings.fallbackToRemoteOnLocalFailure ? "Enabled after local failure" : "Disabled"
        case .appleIntelligence:
            return settings.fallbackToRemoteOnAppleIntelligenceFailure ? "Enabled after Apple Intelligence failure" : "Disabled"
        }
    }

    private static func remoteFallbackWarning(_ settings: CompletionBackendSettings) -> String? {
        switch settings.engineKind {
        case .remote:
            return nil
        case .localLlama where settings.fallbackToRemoteOnLocalFailure:
            return "Remote fallback is enabled: if local completion fails, autocomplete text may be sent to \(settings.remoteBaseURL)."
        case .appleIntelligence where settings.fallbackToRemoteOnAppleIntelligenceFailure:
            return "Remote fallback is enabled: if Apple Intelligence fails, autocomplete text may be sent to \(settings.remoteBaseURL)."
        case .localLlama, .appleIntelligence:
            return nil
        }
    }

    private static func localRuntimeDiagnostic(
        settings: CompletionBackendSettings,
        fileExists: (String) -> Bool,
        loadStatus: LocalLlamaRuntimeStatus
    ) -> LocalLlamaDiagnostic {
        let hasModelPath = !settings.localModelPath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let modelExists = hasModelPath && fileExists(settings.localModelPath)
        let runtimeTitle = settings.localRuntimeState.isAvailable ? "Available" : "Unavailable: \(settings.localRuntimeState.message)"
        let modelFileTitle: String
        if !hasModelPath {
            modelFileTitle = "No model selected"
        } else {
            modelFileTitle = modelExists ? "Found at \(settings.localModelPath)" : "Missing at \(settings.localModelPath)"
        }
        let loadStateTitle: String
        if settings.localRuntimeState.isAvailable && modelExists {
            loadStateTitle = loadStatus.applies(to: settings.localModelPath)
                ? loadStatus.state.title
                : LocalLlamaRuntimeLoadState.unloaded.title
        } else {
            loadStateTitle = "Blocked"
        }
        let lastErrorTitle: String
        if let localLastError = settings.localLastError, !localLastError.isEmpty {
            lastErrorTitle = localLastError
        } else if loadStatus.applies(to: settings.localModelPath),
                  loadStatus.state == .failed,
                  let message = loadStatus.message,
                  !message.isEmpty {
            lastErrorTitle = message
        } else {
            lastErrorTitle = "None"
        }
        let fallbackTitle = settings.fallbackToRemoteOnLocalFailure
            ? "Remote fallback enabled"
            : "Remote fallback disabled"
        let memoryLimitTitle = ByteCountFormatter.string(
            fromByteCount: Int64(min(settings.localMaxRAMBytes, UInt64(Int64.max))),
            countStyle: .memory
        )

        return LocalLlamaDiagnostic(
            runtimeTitle: runtimeTitle,
            modelFileTitle: modelFileTitle,
            loadStateTitle: loadStateTitle,
            lastErrorTitle: lastErrorTitle,
            fallbackTitle: fallbackTitle,
            memoryLimitTitle: memoryLimitTitle,
            isUsable: settings.localRuntimeState.isAvailable && modelExists
        )
    }

    private static func appleIntelligenceDiagnostic(
        settings: CompletionBackendSettings,
        availability: AppleFoundationModelAvailability
    ) -> AppleIntelligenceDiagnostic {
        AppleIntelligenceDiagnostic(
            availabilityTitle: availability.statusTitle,
            requirementTitle: availability.detail,
            fallbackTitle: settings.fallbackToRemoteOnAppleIntelligenceFailure
                ? "Remote fallback enabled"
                : "Remote fallback disabled",
            isUsable: availability.isAvailable
        )
    }

    private static func savedBackendMessage(_ settings: CompletionBackendSettings) -> String {
        switch settings.engineKind {
        case .remote:
            return "Saved Remote OpenAI-compatible: \(settings.remoteModel) at \(settings.remoteBaseURL)."
        case .localLlama:
            return "Saved Local Llama as the selected backend."
        case .appleIntelligence:
            return "Saved Apple Intelligence as the selected backend."
        }
    }

    private static func privacySummary(_ settings: CompletionBackendSettings) -> String {
        switch settings.engineKind {
        case .remote:
            return "Autocomplete text is sent to the configured remote backend."
        case .localLlama:
            return settings.fallbackToRemoteOnLocalFailure
                ? "Runs locally first; remote fallback can send text after a local failure."
                : "Completion requests stay on this Mac when the local runtime is ready."
        case .appleIntelligence:
            return settings.fallbackToRemoteOnAppleIntelligenceFailure
                ? "Uses Apple Intelligence first; remote fallback can send text after a failure."
                : "Completion requests stay on this Mac while Apple Intelligence succeeds."
        }
    }

    private static func privacyStatusTitle(_ settings: CompletionBackendSettings) -> String {
        switch settings.engineKind {
        case .remote:
            return "Remote"
        case .localLlama:
            return settings.fallbackToRemoteOnLocalFailure ? "Fallback" : "Local"
        case .appleIntelligence:
            return settings.fallbackToRemoteOnAppleIntelligenceFailure ? "Fallback" : "Local"
        }
    }

    private static func exposesAutocompleteTextRemotely(_ settings: CompletionBackendSettings) -> Bool {
        switch settings.engineKind {
        case .remote:
            return true
        case .localLlama:
            return settings.fallbackToRemoteOnLocalFailure
        case .appleIntelligence:
            return settings.fallbackToRemoteOnAppleIntelligenceFailure
        }
    }

    private static func isRemoteProviderConfigured(_ settings: CompletionBackendSettings) -> Bool {
        !settings.remoteBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !settings.remoteModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct LocalLlamaDiagnostic: Equatable {
    var runtimeTitle: String
    var modelFileTitle: String
    var loadStateTitle: String
    var lastErrorTitle: String
    var fallbackTitle: String
    var memoryLimitTitle: String
    var isUsable: Bool
}

struct AppleIntelligenceDiagnostic: Equatable {
    var availabilityTitle: String
    var requirementTitle: String
    var fallbackTitle: String
    var isUsable: Bool
}

private extension LocalLlamaRuntimeStatus {
    func applies(to modelPath: String) -> Bool {
        self.modelPath == nil || self.modelPath == modelPath
    }
}
