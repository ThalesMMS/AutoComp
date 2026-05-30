import AutoCompCore

/// Reports whether the currently-selected completion backend is configured enough to be usable.
///
/// Note: this check is intentionally conservative and does not attempt network I/O.
/// Network reachability is handled by `BackendReachabilityHealthCheck`.
struct BackendConfigurationHealthCheck {
    static let id = "backend.configuration"

    let settings: CompletionBackendSettings

    func evaluate() -> HealthCheck {
        switch settings.engineKind {
        case .remote:
            let baseURL = settings.remoteBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            let model = settings.remoteModel.trimmingCharacters(in: .whitespacesAndNewlines)

            var missing: [String] = []
            if baseURL.isEmpty { missing.append("Base URL") }
            if model.isEmpty { missing.append("Model") }

            guard missing.isEmpty else {
                let missingText = missing.joined(separator: ", ")
                return HealthCheck(
                    id: Self.id,
                    title: "Backend Configuration",
                    status: .fail,
                    summary: "Missing \(missingText)",
                    details: "AutoComp is set to use a remote backend, but required settings are missing (\(missingText)). Open Backend Settings to finish setup. Your prompts are only sent to the configured backend when you request a completion.",
                    actions: [
                        HealthRemediationCatalog.openBackendSettings,
                        HealthRemediationCatalog.showBackendConfigurationInstructions
                    ]
                )
            }

            return HealthCheck(
                id: Self.id,
                title: "Backend Configuration",
                status: .ok,
                summary: "Remote backend configured",
                details: "AutoComp will send completion requests to \(baseURL) using model \(model) when you type in supported apps.",
                actions: [
                    HealthRemediationCatalog.openBackendSettings
                ]
            )

        case .localLlama:
            let modelPath = settings.localModelPath.trimmingCharacters(in: .whitespacesAndNewlines)
            if modelPath.isEmpty {
                return HealthCheck(
                    id: Self.id,
                    title: "Backend Configuration",
                    status: .fail,
                    summary: "No local model selected",
                    details: "AutoComp is set to use the local Llama runtime, but no model file path is configured.",
                    actions: [
                        HealthRemediationCatalog.openBackendSettings,
                        HealthRemediationCatalog.showBackendConfigurationInstructions
                    ]
                )
            }

            return HealthCheck(
                id: Self.id,
                title: "Backend Configuration",
                status: .ok,
                summary: "Local model configured",
                details: "Local model path: \(modelPath)",
                actions: [
                    HealthRemediationCatalog.openBackendSettings
                ]
            )

        case .appleIntelligence:
            // Configuration is implicit; availability depends on OS/hardware and is surfaced elsewhere.
            return HealthCheck(
                id: Self.id,
                title: "Backend Configuration",
                status: .ok,
                summary: "Apple Intelligence selected",
                details: "Apple Intelligence availability depends on your macOS version and hardware. If unavailable, enable remote fallback or choose another backend.",
                actions: [
                    HealthRemediationCatalog.openBackendSettings
                ]
            )
        }
    }
}
