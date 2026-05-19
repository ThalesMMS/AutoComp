import Foundation

public final class PrivacySettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    public init(defaults: UserDefaults = .standard, key: String = "privacySettings") {
        self.defaults = defaults
        self.key = key
    }

    public func load() -> PrivacySettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(PrivacySettings.self, from: data) else {
            return PrivacySettings()
        }

        return settings
    }

    public func save(_ settings: PrivacySettings) throws {
        let data = try JSONEncoder().encode(settings)
        defaults.set(data, forKey: key)
    }
}
