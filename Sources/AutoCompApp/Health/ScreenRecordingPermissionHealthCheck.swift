import ApplicationServices
import AutoCompCore

struct ScreenRecordingPermissionHealthCheck {
    static let id = "permission.screen-recording"

    func evaluate() -> HealthCheck {
        // AutoComp uses screen capture permission for visual-context features
        // (e.g., OCR-based geometry fallback and window screenshot pipelines).
        let allowed = CGPreflightScreenCaptureAccess()

        if allowed {
            return HealthCheck(
                id: Self.id,
                title: "Screen Recording",
                status: .ok,
                summary: "Enabled",
                details: "Screen Recording permission allows AutoComp to capture on-screen context for visual features (like screenshot/OCR-based assistance). AutoComp captures only when a feature needs visual context.",
                actions: []
            )
        }

        return HealthCheck(
            id: Self.id,
            title: "Screen Recording",
            status: .warn,
            summary: "Optional (recommended)",
            details: "Screen Recording permission enables visual-context capture (screenshots/OCR). AutoComp can still provide non-visual suggestions without it, but some features may be limited. Enable AutoComp in System Settings > Privacy & Security > Screen Recording, then relaunch the app.",
            actions: [
                HealthRemediationCatalog.openScreenRecordingSystemSettings,
                HealthRemediationCatalog.showScreenRecordingInstructions
            ]
        )
    }
}
