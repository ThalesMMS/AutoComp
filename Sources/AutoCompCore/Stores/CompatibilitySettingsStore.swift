import Foundation

public final class CompatibilitySettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "compatibilityOverrides") {
        self.defaults = defaults
        self.key = key
    }

    public func loadOverrides() -> [String: Bool] {
        defaults.dictionary(forKey: key) as? [String: Bool] ?? [:]
    }

    public func setEnabled(_ enabled: Bool, for bundleID: String) {
        var overrides = loadOverrides()
        overrides[bundleID] = enabled
        defaults.set(overrides, forKey: key)
    }
}
