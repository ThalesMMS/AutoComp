import ApplicationServices
import AutoCompCore

struct AccessibilityPermissionHealthCheck {
    static let id = "permission.accessibility"

    func evaluate() -> HealthCheck {
        let trusted = AXIsProcessTrusted()

        if trusted {
            return HealthCheck(
                id: Self.id,
                title: "Accessibility",
                status: .ok,
                summary: "Enabled",
                details: "Accessibility permission allows AutoComp to read the focused UI context and drive accessibility APIs needed for inline suggestions. AutoComp does not record keystrokes; it uses this access to detect the current editing context and display suggestions.",
                actions: []
            )
        }

        return HealthCheck(
            id: Self.id,
            title: "Accessibility",
            status: .fail,
            summary: "Permission required",
            details: "AutoComp needs Accessibility permission to detect the focused text field and display inline completions. AutoComp does not record audio or video. Enable AutoComp in System Settings > Privacy & Security > Accessibility, then quit and relaunch AutoComp.",
            actions: [
                HealthRemediationCatalog.openAccessibilitySystemSettings,
                HealthRemediationCatalog.showAccessibilityInstructions
            ]
        )
    }
}
