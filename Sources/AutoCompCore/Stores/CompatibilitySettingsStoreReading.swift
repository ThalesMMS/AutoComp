public protocol CompatibilitySettingsStoreReading: Sendable {
    func loadModeOverrides() -> [String: CompatibilityOverrideMode]
}

extension CompatibilitySettingsStore: CompatibilitySettingsStoreReading {}
