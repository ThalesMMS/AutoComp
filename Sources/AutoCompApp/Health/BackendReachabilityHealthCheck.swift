import AutoCompCore

private let backendHealthLogger = AutoCompLogger(category: "health-backend")

/// Reports whether the selected backend is reachable.
///
/// This check relies on existing local state (last probe result + circuit breaker status)
/// rather than performing network requests directly.
struct BackendReachabilityHealthCheck {
    static let id = "backend.reachability"

    let settings: CompletionBackendSettings
    let backendStatus: BackendStatusSummary

    func evaluate() -> HealthCheck {
        switch settings.engineKind {
        case .remote:
            return evaluateRemoteBackend()
        case .localLlama:
            return evaluateLocalBackend()
        case .appleIntelligence:
            return evaluateAppleBackend()
        }
    }

    private func evaluateRemoteBackend() -> HealthCheck {
        let baseURL = settings.remoteBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let model = settings.remoteModel.trimmingCharacters(in: .whitespacesAndNewlines)
        if baseURL.isEmpty || model.isEmpty {
            return HealthCheck(
                id: Self.id,
                title: "Backend Reachability",
                status: .unknown,
                summary: "Test after backend setup.",
                details: "Technical cause: a remote Base URL and Model are required before the connection can be tested.",
                actions: [
                    HealthRemediationCatalog.openBackendSettings,
                    HealthRemediationCatalog.retryBackendConnection
                ]
            )
        }

        backendHealthLogger.info("reachability evaluated: engine=remote state=\(backendStatus.state.rawValue)")
        switch backendStatus.state {
        case .connected:
            return HealthCheck(
                id: Self.id,
                title: "Backend Reachability",
                status: .ok,
                summary: "Completions can reach the backend.",
                details: "Technical details: the remote backend appears reachable. AutoComp contacts it only when generating completions.",
                actions: [
                    HealthRemediationCatalog.retryBackendConnection
                ]
            )
        case .disconnected:
            let reason = backendStatus.issue?.statusReason ?? "Unknown"
            let details = backendStatus.issue?.message
                ?? "AutoComp could not reach the remote backend. Verify the Base URL, model name, and any required credentials."

            return HealthCheck(
                id: Self.id,
                title: "Backend Reachability",
                status: .fail,
                summary: "Completions may fail until it responds.",
                details: "Technical cause (\(reason)): \(details)",
                actions: [
                    HealthRemediationCatalog.openBackendSettings,
                    HealthRemediationCatalog.retryBackendConnection
                ]
            )
        case .paused:
            let reason = backendStatus.issue?.statusReason ?? "Paused"
            let seconds = backendStatus.remainingSuppressionSeconds()
            let countdown = seconds.map { " Try again in \($0)s." } ?? ""

            return HealthCheck(
                id: Self.id,
                title: "Backend Reachability",
                status: .warn,
                summary: "Remote completions are paused.",
                details: "Technical cause (\(reason)): AutoComp temporarily paused remote calls after repeated failures.\(countdown)",
                actions: [
                    HealthRemediationCatalog.retryBackendConnection
                ]
            )
        }
    }

    private func evaluateLocalBackend() -> HealthCheck {
        if backendStatus.state == .connected {
            return HealthCheck(
                id: Self.id,
                title: "Backend Reachability",
                status: .ok,
                summary: "Local completions are ready.",
                details: "Technical details: local generation is enabled.",
                actions: []
            )
        }

        // Local failures should not block overall app usage the same way remote does.
        let reason = backendStatus.issue?.statusReason ?? backendStatus.title
        let details = backendStatus.issue?.message ?? "Local backend is currently unavailable."
        return HealthCheck(
            id: Self.id,
            title: "Backend Reachability",
            status: .warn,
            summary: "Local completions may fail.",
            details: "Technical cause (\(reason)): \(details)",
            actions: [
                HealthRemediationCatalog.openBackendSettings
            ]
        )
    }

    private func evaluateAppleBackend() -> HealthCheck {
        if backendStatus.state == .connected {
            return HealthCheck(
                id: Self.id,
                title: "Backend Reachability",
                status: .ok,
                summary: "Apple Intelligence is ready.",
                details: "Technical details: the Apple Intelligence backend appears available.",
                actions: []
            )
        }

        let reason = backendStatus.issue?.statusReason ?? backendStatus.title
        let details = backendStatus.issue?.message ?? "Apple Intelligence backend is currently unavailable."
        return HealthCheck(
            id: Self.id,
            title: "Backend Reachability",
            status: .warn,
            summary: "Apple Intelligence may not respond.",
            details: "Technical cause (\(reason)): \(details)",
            actions: [
                HealthRemediationCatalog.openBackendSettings
            ]
        )
    }
}
