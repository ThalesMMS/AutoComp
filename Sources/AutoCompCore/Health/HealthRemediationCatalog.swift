import Foundation

public enum HealthRemediationCatalog {
    public static let openAccessibilitySystemSettings = HealthRemediationAction(
        id: "open.accessibility.system-settings",
        title: "Open Accessibility Settings",
        kind: .openSystemSettings,
        url: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    )

    public static let openInputMonitoringSystemSettings = HealthRemediationAction(
        id: "open.input-monitoring.system-settings",
        title: "Open Input Monitoring Settings",
        kind: .openSystemSettings,
        url: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")
    )

    public static let openScreenRecordingSystemSettings = HealthRemediationAction(
        id: "open.screen-recording.system-settings",
        title: "Open Screen Recording Settings",
        kind: .openSystemSettings,
        url: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    )

    public static let showAccessibilityInstructions = HealthRemediationAction(
        id: "instructions.accessibility",
        title: "How to enable Accessibility",
        kind: .showInstructions,
        payload: "Open System Settings → Privacy & Security → Accessibility, then enable AutoComp. You may need to quit and reopen the app."
    )

    public static let showInputMonitoringInstructions = HealthRemediationAction(
        id: "instructions.input-monitoring",
        title: "How to enable Input Monitoring",
        kind: .showInstructions,
        payload: "Open System Settings → Privacy & Security → Input Monitoring, then enable AutoComp. If the toggle is missing, ensure you are running the app from /Applications and try again."
    )

    public static let showScreenRecordingInstructions = HealthRemediationAction(
        id: "instructions.screen-recording",
        title: "How to enable Screen Recording",
        kind: .showInstructions,
        payload: "Open System Settings → Privacy & Security → Screen Recording, then enable AutoComp. Relaunch AutoComp after enabling."
    )

    public static let openBackendSettings = HealthRemediationAction(
        id: "open.in-app.backend-settings",
        title: "Open Backend Settings",
        kind: .openInAppSettings,
        payload: "settings.backend"
    )

    public static let openCompatibilitySettings = HealthRemediationAction(
        id: "open.in-app.compatibility-settings",
        title: "Open Compatibility Settings",
        kind: .openInAppSettings,
        payload: "settings.compatibility"
    )

    public static let retryBackendConnection = HealthRemediationAction(
        id: "retry.backend.connection",
        title: "Test Connection",
        kind: .retry,
        payload: "backend.test-connection"
    )

    public static let showBackendConfigurationInstructions = HealthRemediationAction(
        id: "instructions.backend.configuration",
        title: "How to configure the backend",
        kind: .showInstructions,
        payload: "Open AutoComp Settings → Backend. Choose a backend and fill in the required fields (Remote: Base URL + Model; Local Llama: Model file; Apple Intelligence: availability depends on macOS/hardware). Then click Test Connection."
    )
}
