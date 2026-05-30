import Foundation

public final class CompatibilitySettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let legacyEnabledKey: String
    private let modeKey: String

    public init(
        defaults: UserDefaults = .standard,
        key: String = "compatibilityOverrides",
        modeKey: String = "compatibilityModeOverrides"
    ) {
        self.defaults = defaults
        self.legacyEnabledKey = key
        self.modeKey = modeKey
    }

    public func loadOverrides() -> [String: Bool] {
        loadModeOverrides().mapValues { $0 != .disabled }
    }

    public func loadModeOverrides() -> [String: CompatibilityOverrideMode] {
        if let rawModes = defaults.dictionary(forKey: modeKey) as? [String: String] {
            return rawModes.compactMapValues(CompatibilityOverrideMode.init(rawValue:))
        }

        let legacyOverrides = defaults.dictionary(forKey: legacyEnabledKey) as? [String: Bool] ?? [:]
        return legacyOverrides.mapValues { $0 ? .automatic : .disabled }
    }

    public func setEnabled(_ enabled: Bool, for bundleID: String) {
        setMode(enabled ? .automatic : .disabled, for: bundleID)
    }

    public func setMode(_ mode: CompatibilityOverrideMode?, for bundleID: String) {
        setMode(mode, forKey: bundleID)
    }

    public func setMode(_ mode: CompatibilityOverrideMode?, forDomain domain: String) {
        let normalizedDomain = DomainNormalization.canonicalDomainStringAllowingEmpty(from: domain)
        guard !normalizedDomain.isEmpty else {
            return
        }
        setMode(mode, forKey: CompatibilityCatalog.overrideKey(forDomain: normalizedDomain))
    }

    public func loadDomainModeOverrides() -> [String: CompatibilityOverrideMode] {
        loadModeOverrides().reduce(into: [:]) { result, pair in
            guard pair.key.hasPrefix("domain:") else {
                return
            }
            let domain = String(pair.key.dropFirst("domain:".count))
            result[domain] = pair.value
        }
    }

    private func setMode(_ mode: CompatibilityOverrideMode?, forKey key: String) {
        var overrides = loadModeOverrides()
        if let mode {
            overrides[key] = mode
        } else {
            overrides.removeValue(forKey: key)
        }
        saveModeOverrides(overrides)
    }

    public func resetOverrides() {
        defaults.removeObject(forKey: modeKey)
        defaults.removeObject(forKey: legacyEnabledKey)
    }

    private func saveModeOverrides(_ overrides: [String: CompatibilityOverrideMode]) {
        let rawModes = overrides.mapValues(\.rawValue)
        defaults.set(rawModes, forKey: modeKey)
    }
}
