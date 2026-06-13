import AutoCompCore

struct PermissionHealthCheck {
    let kind: PermissionKind
    let isAllowed: Bool

    init(kind: PermissionKind, isAllowed: Bool) {
        self.kind = kind
        self.isAllowed = isAllowed
    }

    func evaluate() -> HealthCheck {
        if isAllowed {
            return HealthCheck(
                id: kind.healthCheckID,
                title: kind.title,
                status: .ok,
                summary: kind.healthGrantedSummary,
                details: kind.healthGrantedDetails,
                actions: []
            )
        }

        return HealthCheck(
            id: kind.healthCheckID,
            title: kind.title,
            status: kind.healthMissingStatus,
            summary: kind.healthMissingSummary,
            details: kind.healthMissingDetails,
            actions: kind.healthRemediationActions
        )
    }
}

extension PermissionKind {
    var healthCheckID: String {
        switch self {
        case .accessibility:
            return "permission.accessibility"
        case .inputMonitoring:
            return "permission.input-monitoring"
        case .screenRecording:
            return "permission.screen-recording"
        }
    }

    var healthGrantedSummary: String {
        switch self {
        case .accessibility:
            return "Suggestions can attach to text fields."
        case .inputMonitoring:
            return "Shortcut acceptance is ready."
        case .screenRecording:
            return "Visual context is ready."
        }
    }

    var healthGrantedDetails: String {
        switch self {
        case .accessibility:
            return "Technical cause: Accessibility is enabled. AutoComp uses it to read focused text-field context and place inline suggestions. It does not record audio or video."
        case .inputMonitoring:
            return "Technical cause: Input Monitoring is enabled. AutoComp uses it only to detect global accept and dismiss shortcuts; it does not store typed text."
        case .screenRecording:
            return "Technical cause: Screen Recording is enabled. AutoComp can capture on-screen context only when a feature needs visual context."
        }
    }

    var healthMissingStatus: HealthStatus {
        requirement == .required ? .fail : .warn
    }

    var healthMissingSummary: String {
        switch self {
        case .accessibility:
            return "Suggestions cannot attach yet."
        case .inputMonitoring:
            return "Shortcut acceptance cannot run yet."
        case .screenRecording:
            return "Visual context is off."
        }
    }

    var healthMissingDetails: String {
        switch self {
        case .accessibility:
            return "Technical cause: Accessibility is off. AutoComp needs it to detect the focused text field and display inline completions. Enable AutoComp in System Settings > Privacy & Security > Accessibility, then quit and relaunch AutoComp."
        case .inputMonitoring:
            return "Technical cause: Input Monitoring is off. AutoComp needs it to detect global shortcuts such as accepting a suggestion. Enable AutoComp in System Settings > Privacy & Security > Input Monitoring, then quit and relaunch AutoComp."
        case .screenRecording:
            return "Technical cause: Screen Recording is off. Text-field suggestions still work, but screenshot and OCR-based visual features stay limited. Enable AutoComp in System Settings > Privacy & Security > Screen Recording, then relaunch the app."
        }
    }

    var healthRemediationActions: [HealthRemediationAction] {
        switch self {
        case .accessibility:
            return [
                HealthRemediationCatalog.openAccessibilitySystemSettings,
                HealthRemediationCatalog.showAccessibilityInstructions
            ]
        case .inputMonitoring:
            return [
                HealthRemediationCatalog.openInputMonitoringSystemSettings,
                HealthRemediationCatalog.showInputMonitoringInstructions
            ]
        case .screenRecording:
            return [
                HealthRemediationCatalog.openScreenRecordingSystemSettings,
                HealthRemediationCatalog.showScreenRecordingInstructions
            ]
        }
    }
}
