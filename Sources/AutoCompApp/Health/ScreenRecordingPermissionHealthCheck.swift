import AutoCompCore

struct ScreenRecordingPermissionHealthCheck {
    static let id = "permission.screen-recording"
    let allowed: Bool

    init(allowed: Bool) {
        self.allowed = allowed
    }

    func evaluate() -> HealthCheck {
        if allowed {
            return HealthCheck(
                id: Self.id,
                title: "Screen Recording",
                status: .ok,
                summary: "Visual context is ready.",
                details: "Technical cause: Screen Recording is enabled. AutoComp can capture on-screen context only when a feature needs visual context.",
                actions: []
            )
        }

        return HealthCheck(
            id: Self.id,
            title: "Screen Recording",
            status: .warn,
            summary: "Visual context is off.",
            details: "Technical cause: Screen Recording is off. Text-field suggestions still work, but screenshot and OCR-based visual features stay limited. Enable AutoComp in System Settings > Privacy & Security > Screen Recording, then relaunch the app.",
            actions: [
                HealthRemediationCatalog.openScreenRecordingSystemSettings,
                HealthRemediationCatalog.showScreenRecordingInstructions
            ]
        )
    }
}
