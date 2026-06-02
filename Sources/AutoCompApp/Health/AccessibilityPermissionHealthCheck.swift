import AutoCompCore

struct AccessibilityPermissionHealthCheck {
    static let id = "permission.accessibility"
    let trusted: Bool

    init(trusted: Bool) {
        self.trusted = trusted
    }

    func evaluate() -> HealthCheck {
        if trusted {
            return HealthCheck(
                id: Self.id,
                title: "Accessibility",
                status: .ok,
                summary: "Suggestions can attach to text fields.",
                details: "Technical cause: Accessibility is enabled. AutoComp uses it to read focused text-field context and place inline suggestions. It does not record audio or video.",
                actions: []
            )
        }

        return HealthCheck(
            id: Self.id,
            title: "Accessibility",
            status: .fail,
            summary: "Suggestions cannot attach yet.",
            details: "Technical cause: Accessibility is off. AutoComp needs it to detect the focused text field and display inline completions. Enable AutoComp in System Settings > Privacy & Security > Accessibility, then quit and relaunch AutoComp.",
            actions: [
                HealthRemediationCatalog.openAccessibilitySystemSettings,
                HealthRemediationCatalog.showAccessibilityInstructions
            ]
        )
    }
}
