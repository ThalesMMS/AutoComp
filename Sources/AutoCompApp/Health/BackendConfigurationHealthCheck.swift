import AutoCompCore
import Foundation

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
                    summary: "Completions need \(missingText).",
                    details: "Technical cause: the remote backend is selected, but required settings are missing (\(missingText)). Open Backend Settings to finish setup. Prompts are sent only when you request a completion.",
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
                summary: "Completions use the remote model.",
                details: "Technical details: completion requests go to \(baseURL) using model \(model) when you type in supported apps.",
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
                    summary: "Choose a local model file.",
                    details: "Technical cause: the local runtime is selected, but no model file path is configured.",
                    actions: [
                        HealthRemediationCatalog.openBackendSettings,
                        HealthRemediationCatalog.showBackendConfigurationInstructions
                    ]
                )
            }

            let modelURL = URL(fileURLWithPath: modelPath)
            guard FileManager.default.fileExists(atPath: modelPath) else {
                return HealthCheck(
                    id: Self.id,
                    title: "Backend Configuration",
                    status: .fail,
                    summary: "Selected local model is missing.",
                    details: "Technical cause: \(modelURL.lastPathComponent) is selected, but the file is no longer installed. Import, download, or choose another GGUF model.",
                    actions: [
                        HealthRemediationCatalog.openBackendSettings,
                        HealthRemediationCatalog.showBackendConfigurationInstructions
                    ]
                )
            }

            do {
                try ModelFileValidator.validateGGUFFile(at: modelURL)
            } catch {
                let message = ((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
                    .replacingOccurrences(of: modelPath, with: modelURL.lastPathComponent)
                return HealthCheck(
                    id: Self.id,
                    title: "Backend Configuration",
                    status: .fail,
                    summary: "Selected local model is not valid.",
                    details: "Technical cause for \(modelURL.lastPathComponent): \(message)",
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
                summary: "Local completions are configured.",
                details: "Technical details: local model \(modelURL.lastPathComponent) is installed and readable.",
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
                summary: "Apple Intelligence is selected.",
                details: "Technical details: availability depends on your macOS version and hardware. If unavailable, enable remote fallback or choose another backend.",
                actions: [
                    HealthRemediationCatalog.openBackendSettings
                ]
            )
        }
    }
}
