import AutoCompCore

struct InputMonitoringPermissionHealthCheck {
    static let id = "permission.input-monitoring"
    let allowed: Bool

    init(allowed: Bool) {
        self.allowed = allowed
    }

    func evaluate() -> HealthCheck {
        if allowed {
            return HealthCheck(
                id: Self.id,
                title: "Input Monitoring",
                status: .ok,
                summary: "Shortcut acceptance is ready.",
                details: "Technical cause: Input Monitoring is enabled. AutoComp uses it only to detect global accept and dismiss shortcuts; it does not store typed text.",
                actions: []
            )
        }

        return HealthCheck(
            id: Self.id,
            title: "Input Monitoring",
            status: .fail,
            summary: "Shortcut acceptance cannot run yet.",
            details: "Technical cause: Input Monitoring is off. AutoComp needs it to detect global shortcuts such as accepting a suggestion. Enable AutoComp in System Settings > Privacy & Security > Input Monitoring, then quit and relaunch AutoComp.",
            actions: [
                HealthRemediationCatalog.openInputMonitoringSystemSettings,
                HealthRemediationCatalog.showInputMonitoringInstructions
            ]
        )
    }
}
