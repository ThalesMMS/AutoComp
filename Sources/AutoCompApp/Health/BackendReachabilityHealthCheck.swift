import AutoCompCore

private let backendHealthLogger = AutoCompLogger(category: "health-backend")

/// Reports whether the selected backend is reachable.
///
/// This check relies on existing telemetry/state (last probe result + circuit breaker status)
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
                summary: "Not configured yet",
                details: "Configure a remote Base URL and Model, then test the connection.",
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
                summary: "Connected",
                details: "Remote backend appears reachable. AutoComp will only contact it when generating completions.",
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
                summary: "Disconnected (\(reason))",
                details: details,
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
                summary: "Paused (\(reason))",
                details: "AutoComp temporarily paused remote calls after repeated failures.\(countdown)",
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
                summary: "Local backend ready",
                details: "Local generation is enabled.",
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
            summary: "Not ready (\(reason))",
            details: details,
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
                summary: "Available",
                details: "Apple Intelligence backend appears available.",
                actions: []
            )
        }

        let reason = backendStatus.issue?.statusReason ?? backendStatus.title
        let details = backendStatus.issue?.message ?? "Apple Intelligence backend is currently unavailable."
        return HealthCheck(
            id: Self.id,
            title: "Backend Reachability",
            status: .warn,
            summary: "Unavailable (\(reason))",
            details: details,
            actions: [
                HealthRemediationCatalog.openBackendSettings
            ]
        )
    }
}
