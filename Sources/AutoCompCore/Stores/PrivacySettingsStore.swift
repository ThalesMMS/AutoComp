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

        var migratedSettings = settings
        migratedSettings.telemetryEnabled = false
        return migratedSettings
    }

    public func save(_ settings: PrivacySettings) throws {
        var storedSettings = settings
        storedSettings.telemetryEnabled = false
        let data = try JSONEncoder().encode(storedSettings)
        defaults.set(data, forKey: key)
    }

    public func resetWritingPreferences() throws {
        var settings = load()
        settings.writingPreferences = WritingPreferences()
        try save(settings)
    }

    public func resetLocalPrivacyDataState() throws {
        var settings = load()
        settings.telemetryEnabled = false
        settings.writingPreferences = WritingPreferences()
        try save(settings)
    }
}
