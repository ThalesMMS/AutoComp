import Foundation

public final class PrivacySettingsStore: @unchecked Sendable {
    private let defaults: MirroredUserDefaults
    private let key: String
    private let lock = NSLock()
    private var cachedSettings: PrivacySettings?

    public init(defaults: UserDefaults = .standard, key: String = "privacySettings") {
        self.defaults = MirroredUserDefaults(primary: defaults)
        self.key = key
    }

    public func load() -> PrivacySettings {
        lock.lock()
        defer { lock.unlock() }

        if let cachedSettings {
            return cachedSettings
        }

        guard let settings = defaults.decode(PrivacySettings.self, forKey: key) else {
            let settings = PrivacySettings()
            cachedSettings = settings
            return settings
        }

        cachedSettings = settings
        return settings
    }

    public func save(_ settings: PrivacySettings) throws {
        lock.lock()
        defer { lock.unlock() }
        try defaults.encode(settings, forKey: key)
        cachedSettings = settings
    }

    public func resetWritingPreferences() throws {
        var settings = load()
        settings.writingPreferences = WritingPreferences()
        try save(settings)
    }

    public func resetLocalPrivacyDataState() throws {
        var settings = load()
        settings.localPersonalizationEnabled = false
        settings.writingPreferences = WritingPreferences()
        try save(settings)
    }
}
