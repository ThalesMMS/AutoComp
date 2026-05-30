import AutoCompCore

struct HostAppCompatibilityHealthCheck {
    static let id = "compatibility.focusedApp"

    private let snapshotProvider: () -> FocusTrackingSnapshot?
    private let compatibilityCatalog: CompatibilityCatalog
    private let compatibilitySettingsStore: CompatibilitySettingsStoreReading

    init(
        snapshotProvider: @escaping () -> FocusTrackingSnapshot?,
        compatibilityCatalog: CompatibilityCatalog = CompatibilityCatalog(),
        compatibilitySettingsStore: CompatibilitySettingsStoreReading = CompatibilitySettingsStore()
    ) {
        self.snapshotProvider = snapshotProvider
        self.compatibilityCatalog = compatibilityCatalog
        self.compatibilitySettingsStore = compatibilitySettingsStore
    }

    init(
        focusTrackingModel: FocusTrackingModel,
        compatibilityCatalog: CompatibilityCatalog = CompatibilityCatalog(),
        compatibilitySettingsStore: CompatibilitySettingsStoreReading = CompatibilitySettingsStore()
    ) {
        self.snapshotProvider = { focusTrackingModel.snapshot }
        self.compatibilityCatalog = compatibilityCatalog
        self.compatibilitySettingsStore = compatibilitySettingsStore
    }

    func evaluate() -> HealthCheck {
        guard let snapshot = snapshotProvider() else {
            return HealthCheck(
                id: Self.id,
                title: "Focused app",
                status: .unknown,
                summary: "No focused app",
                details: "AutoComp couldn't determine the current focused app. Switch to an app and focus a text field, then try again.",
                actions: []
            )
        }

        let context = snapshot.context
        let bundleID = context.app.bundleID
        let appName = context.app.displayName

        let overrides = compatibilitySettingsStore.loadModeOverrides()
        let decision = compatibilityCatalog.decision(
            bundleID: bundleID,
            domain: context.domain,
            userModeOverrides: overrides
        )

        let status: HealthStatus
        let summary: String
        let details: String
        var actions: [HealthRemediationAction] = []

        if decision.profile.status == .unsupported || decision.overrideMode == .disabled {
            status = .fail
            summary = "Disabled"
            let baseReason = decision.profile.status == .unsupported
                ? (decision.profile.notes.isEmpty ? "This app is currently unsupported." : decision.profile.notes)
                : "AutoComp is disabled for this app."
            details = "\(appName) (\(bundleID))\n\n\(baseReason)"
            actions.append(HealthRemediationCatalog.openCompatibilitySettings)
        } else if decision.overrideMode == .manualOnly {
            status = .warn
            summary = "Manual only"
            let note = decision.profile.notes.isEmpty ? "" : "\n\n\(decision.profile.notes)"
            details = "\(appName) (\(bundleID))\n\nSuggestions are available, but won't appear automatically. Use the manual trigger shortcut to request a suggestion.\(note)"
            actions.append(HealthRemediationCatalog.openCompatibilitySettings)
        } else {
            status = .ok
            summary = "Enabled"
            var detailLines: [String] = ["\(appName) (\(bundleID))", "", "Automatic suggestions are enabled for this app."]
            if let setup = decision.setupMessage {
                detailLines.append("\nSetup needed: \(setup)")
            } else if !decision.profile.notes.isEmpty {
                detailLines.append("\n\(decision.profile.notes)")
            }
            if let warning = decision.warningMessage {
                detailLines.append("\n\(warning)")
            }
            details = detailLines.joined(separator: "\n")
            actions.append(HealthRemediationCatalog.openCompatibilitySettings)
        }

        return HealthCheck(
            id: Self.id,
            title: "Focused app",
            status: status,
            summary: summary,
            details: details,
            actions: actions
        )
    }
}
