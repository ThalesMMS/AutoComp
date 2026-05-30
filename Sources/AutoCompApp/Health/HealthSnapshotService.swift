import Combine
import Foundation
import AutoCompCore

private let healthSnapshotLogger = AutoCompLogger(category: "health-snapshot")

@MainActor
final class HealthSnapshotService: ObservableObject, HealthSnapshotServicing {
    @Published private(set) var snapshot: HealthSnapshot = HealthSnapshot(checks: [])

    private let permissionService: PermissionService
    private let focusTrackingModel: FocusTrackingModel
    private let completionBackendConfigurationService: CompletionBackendConfigurationService
    private let compatibilityCatalog: CompatibilityCatalog
    private let compatibilitySettings: CompatibilitySettingsStore
    private let backendStatusProvider: () -> BackendStatusSummary

    private var cancellables: Set<AnyCancellable> = []

    init(
        permissionService: PermissionService,
        focusTrackingModel: FocusTrackingModel,
        completionBackendConfigurationService: CompletionBackendConfigurationService,
        compatibilityCatalog: CompatibilityCatalog,
        compatibilitySettings: CompatibilitySettingsStore,
        backendStatusProvider: @escaping () -> BackendStatusSummary
    ) {
        self.permissionService = permissionService
        self.focusTrackingModel = focusTrackingModel
        self.completionBackendConfigurationService = completionBackendConfigurationService
        self.compatibilityCatalog = compatibilityCatalog
        self.compatibilitySettings = compatibilitySettings
        self.backendStatusProvider = backendStatusProvider

        // Coalesce bursts of signals into a single refresh.
        permissionService.$accessibilityTrusted
            .removeDuplicates()
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        permissionService.$inputMonitoringAllowed
            .removeDuplicates()
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        permissionService.$screenRecordingAllowed
            .removeDuplicates()
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        focusTrackingModel.$snapshot
            .map(HealthFocusSignature.init(snapshot:))
            .removeDuplicates()
            .sink { [weak self] _ in self?.refresh() }
            .store(in: &cancellables)

        // Backend settings are not published; do a lightweight polling refresh when asked by UI.
        // For now, changes are picked up when refresh() is called.

        refresh()
    }

    func refresh() {
        let backendSettings = completionBackendConfigurationService.load()
        healthSnapshotLogger.info("refresh requested")

        let checks: [HealthCheck] = [
            AccessibilityPermissionHealthCheck().evaluate(),
            InputMonitoringPermissionHealthCheck().evaluate(),
            ScreenRecordingPermissionHealthCheck().evaluate(),
            BackendConfigurationHealthCheck(settings: backendSettings).evaluate(),
            BackendReachabilityHealthCheck(
                settings: backendSettings,
                backendStatus: backendStatusProvider()
            ).evaluate(),
            HostAppCompatibilityHealthCheck(
                focusTrackingModel: focusTrackingModel,
                compatibilityCatalog: compatibilityCatalog,
                compatibilitySettingsStore: compatibilitySettings
            ).evaluate()
        ]

        // Avoid showing empty UI states when a check returns no actionable information.
        // Also keep ordering stable for the dashboard.
        snapshot = HealthSnapshot(checks: checks.filter { !$0.isEmpty })
    }
}

private struct HealthFocusSignature: Equatable {
    let app: AppIdentity?
    let domain: String?
    let focusChangeSequence: UInt64?
    let capability: FocusFieldCapability?
    let rejectionReason: String?

    init(snapshot: FocusTrackingSnapshot?) {
        self.app = snapshot?.context.app
        self.domain = snapshot?.context.domain
        self.focusChangeSequence = snapshot?.focusChangeSequence
        self.capability = snapshot?.capability
        self.rejectionReason = snapshot?.rejectionReason
    }
}
