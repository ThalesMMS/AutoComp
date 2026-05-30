import ApplicationServices
import AutoCompCore

struct InputMonitoringPermissionHealthCheck {
    static let id = "permission.input-monitoring"

    func evaluate() -> HealthCheck {
        // PermissionService's policy treats CGPreflightListenEventAccess() as the
        // authoritative signal for whether global shortcuts can be installed.
        //
        // Some environments (sandboxed builds, CI, or future OS changes) can make this
        // signal indeterminate. In that case, we surface an `.unknown` state so the
        // dashboard can explain what happened rather than incorrectly failing.
        let allowed = CGPreflightListenEventAccess()

        // If the system reports neither granted nor denied, treat it as indeterminate.
        // This can happen briefly after toggling the setting or in some restricted environments.
        if !allowed {
            // NOTE: There's no official tri-state API for Input Monitoring. We only emit `.unknown`
            // when we can't even ask the user to remediate (e.g., if System Settings deep link is
            // unavailable). Since we do have a deep link, we keep this as a fail.
        }

        if allowed {
            return HealthCheck(
                id: Self.id,
                title: "Input Monitoring",
                status: .ok,
                summary: "Enabled",
                details: "Input Monitoring permission allows AutoComp to detect global keyboard shortcuts used to accept or dismiss suggestions. AutoComp does not log typed text; this permission is used only for shortcut detection.",
                actions: []
            )
        }

        return HealthCheck(
            id: Self.id,
            title: "Input Monitoring",
            status: .fail,
            summary: "Permission required",
            details: "AutoComp needs Input Monitoring permission to detect global shortcuts (for example, accepting a suggestion). AutoComp does not capture or store your keystrokes. Enable AutoComp in System Settings > Privacy & Security > Input Monitoring, then quit and relaunch AutoComp.",
            actions: [
                HealthRemediationCatalog.openInputMonitoringSystemSettings,
                HealthRemediationCatalog.showInputMonitoringInstructions
            ]
        )
    }
}
