import AutoCompCore
import Foundation

enum RedactedSettingsTransferError: LocalizedError, Equatable {
    case invalidSchema(String)
    case unsupportedVersion(Int)

    var errorDescription: String? {
        switch self {
        case .invalidSchema(let schema):
            return "Unsupported settings export schema: \(schema)."
        case .unsupportedVersion(let version):
            return "Unsupported settings export version: \(version)."
        }
    }
}

struct RedactedSettingsPackage: Codable, Equatable {
    static let schemaName = "com.autocomp.redacted-settings"
    static let supportedVersion = 1

    var schema: String
    var version: Int
    var exportedAt: Date
    var compatibility: RedactedCompatibilitySettings
    var privacy: RedactedPrivacySettings
    var shortcuts: KeyboardShortcutSettings
    var overlay: RedactedOverlaySettings
    var backend: RedactedBackendSettings

    init(
        schema: String = Self.schemaName,
        version: Int = Self.supportedVersion,
        exportedAt: Date = Date(),
        compatibility: RedactedCompatibilitySettings,
        privacy: RedactedPrivacySettings,
        shortcuts: KeyboardShortcutSettings,
        overlay: RedactedOverlaySettings,
        backend: RedactedBackendSettings
    ) {
        self.schema = schema
        self.version = version
        self.exportedAt = exportedAt
        self.compatibility = compatibility
        self.privacy = privacy
        self.shortcuts = shortcuts
        self.overlay = overlay
        self.backend = backend
    }
}

struct RedactedCompatibilitySettings: Codable, Equatable {
    var appOverrides: [String: CompatibilityOverrideMode]
    var domainOverrides: [String: CompatibilityOverrideMode]
}

struct RedactedPrivacySettings: Codable, Equatable {
    var collectionEnabled: Bool
    var clipboardContextEnabled: Bool
    var screenContextEnabled: Bool
    var productivityMetricsEnabled: Bool
    var domainRules: [String: Bool]
}

struct RedactedOverlaySettings: Codable, Equatable {
    var safeModeEnabled: Bool
}

struct RedactedBackendSettings: Codable, Equatable {
    var engineKind: CompletionEngineKind
    var remoteBaseURL: String
    var remoteModel: String
    var localModelBasename: String?
    var localMaxRAMBytes: UInt64
    var fallbackToRemoteOnLocalFailure: Bool
    var fallbackToRemoteOnAppleIntelligenceFailure: Bool
    var multiSuggestionEnabled: Bool
    var stopSequences: CompletionStopSequences
}

struct RedactedSettingsImportPreview: Equatable {
    var package: RedactedSettingsPackage
    var rows: [RedactedSettingsPreviewRow]
    var warnings: [String]

    var summary: String {
        "\(rows.count) setting groups ready to import"
    }
}

struct RedactedSettingsPreviewRow: Identifiable, Equatable {
    var id: String
    var title: String
    var currentValue: String
    var importedValue: String
}

enum RedactedSettingsTransfer {
    static func exportFilename(now: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: now)
            .replacingOccurrences(of: ":", with: "-")
        return "AutoComp-Redacted-Settings-\(stamp).json"
    }

    static func package(
        compatibilityOverrides: [String: CompatibilityOverrideMode],
        privacySettings: PrivacySettings,
        shortcutSettings: KeyboardShortcutSettings,
        backendSettings: CompletionBackendSettings,
        safeOverlayModeEnabled: Bool,
        exportedAt: Date = Date()
    ) -> RedactedSettingsPackage {
        RedactedSettingsPackage(
            exportedAt: exportedAt,
            compatibility: RedactedCompatibilitySettings(
                appOverrides: compatibilityOverrides.filter { !$0.key.hasPrefix("domain:") },
                domainOverrides: compatibilityOverrides.reduce(into: [:]) { result, pair in
                    guard pair.key.hasPrefix("domain:") else {
                        return
                    }
                    result[String(pair.key.dropFirst("domain:".count))] = pair.value
                }
            ),
            privacy: RedactedPrivacySettings(
                collectionEnabled: privacySettings.collectionEnabled,
                clipboardContextEnabled: privacySettings.clipboardContextEnabled,
                screenContextEnabled: privacySettings.screenContextEnabled,
                productivityMetricsEnabled: privacySettings.productivityMetricsEnabled,
                domainRules: privacySettings.perDomainRules
            ),
            shortcuts: shortcutSettings,
            overlay: RedactedOverlaySettings(safeModeEnabled: safeOverlayModeEnabled),
            backend: RedactedBackendSettings(
                engineKind: backendSettings.engineKind,
                remoteBaseURL: sanitizedRemoteBaseURL(backendSettings.remoteBaseURL),
                remoteModel: backendSettings.remoteModel,
                localModelBasename: localModelBasename(from: backendSettings.localModelPath),
                localMaxRAMBytes: backendSettings.localMaxRAMBytes,
                fallbackToRemoteOnLocalFailure: backendSettings.fallbackToRemoteOnLocalFailure,
                fallbackToRemoteOnAppleIntelligenceFailure: backendSettings.fallbackToRemoteOnAppleIntelligenceFailure,
                multiSuggestionEnabled: backendSettings.multiSuggestionEnabled,
                stopSequences: backendSettings.stopSequences
            )
        )
    }

    static func encodedData(for package: RedactedSettingsPackage) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(package)
    }

    static func decodedPackage(from data: Data) throws -> RedactedSettingsPackage {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let package = try decoder.decode(RedactedSettingsPackage.self, from: data)
        try validate(package)
        return package
    }

    static func validate(_ package: RedactedSettingsPackage) throws {
        guard package.schema == RedactedSettingsPackage.schemaName else {
            throw RedactedSettingsTransferError.invalidSchema(package.schema)
        }
        guard package.version == RedactedSettingsPackage.supportedVersion else {
            throw RedactedSettingsTransferError.unsupportedVersion(package.version)
        }
    }

    static func preview(
        package: RedactedSettingsPackage,
        currentCompatibilityOverrides: [String: CompatibilityOverrideMode],
        currentPrivacySettings: PrivacySettings,
        currentShortcutSettings: KeyboardShortcutSettings,
        currentBackendSettings: CompletionBackendSettings,
        safeOverlayModeEnabled: Bool
    ) -> RedactedSettingsImportPreview {
        let importedCompatibilityOverrides = compatibilityOverrides(from: package.compatibility)
        let rows = [
            RedactedSettingsPreviewRow(
                id: "compatibility-apps",
                title: "App compatibility rules",
                currentValue: "\(currentCompatibilityOverrides.filter { !$0.key.hasPrefix("domain:") }.count)",
                importedValue: "\(package.compatibility.appOverrides.count)"
            ),
            RedactedSettingsPreviewRow(
                id: "compatibility-domains",
                title: "Domain compatibility rules",
                currentValue: "\(currentCompatibilityOverrides.filter { $0.key.hasPrefix("domain:") }.count)",
                importedValue: "\(package.compatibility.domainOverrides.count)"
            ),
            RedactedSettingsPreviewRow(
                id: "privacy-domains",
                title: "Domain privacy rules",
                currentValue: "\(currentPrivacySettings.perDomainRules.count)",
                importedValue: "\(package.privacy.domainRules.count)"
            ),
            RedactedSettingsPreviewRow(
                id: "privacy-sources",
                title: "Privacy source toggles",
                currentValue: privacySourceSummary(currentPrivacySettings),
                importedValue: privacySourceSummary(package.privacy)
            ),
            RedactedSettingsPreviewRow(
                id: "shortcuts",
                title: "Shortcut bindings",
                currentValue: shortcutSummary(currentShortcutSettings),
                importedValue: shortcutSummary(package.shortcuts)
            ),
            RedactedSettingsPreviewRow(
                id: "backend",
                title: "Backend",
                currentValue: backendSummary(currentBackendSettings),
                importedValue: backendSummary(package.backend)
            ),
            RedactedSettingsPreviewRow(
                id: "local-model",
                title: "Local model path",
                currentValue: localModelBasename(from: currentBackendSettings.localModelPath) ?? "none",
                importedValue: package.backend.localModelBasename.map { "\($0) (basename only)" } ?? "preserve current"
            ),
            RedactedSettingsPreviewRow(
                id: "safe-overlay",
                title: "Safe overlay mode",
                currentValue: safeOverlayModeEnabled ? "active" : "off",
                importedValue: package.overlay.safeModeEnabled ? "active" : "off"
            )
        ]

        var warnings = [
            "Remote API key is not included and will be preserved locally.",
            "Local model path is not included and will be preserved locally.",
            "Safe overlay mode is launch-time state; import records it for comparison but does not toggle it."
        ]
        if importedCompatibilityOverrides == currentCompatibilityOverrides,
           package.privacy.domainRules == currentPrivacySettings.perDomainRules,
           package.shortcuts == currentShortcutSettings {
            warnings.append("Imported app/domain rules and shortcuts match current settings.")
        }

        return RedactedSettingsImportPreview(
            package: package,
            rows: rows,
            warnings: warnings
        )
    }

    static func compatibilityOverrides(from settings: RedactedCompatibilitySettings) -> [String: CompatibilityOverrideMode] {
        var overrides = settings.appOverrides
        for (domain, mode) in settings.domainOverrides {
            overrides[CompatibilityCatalog.overrideKey(forDomain: domain)] = mode
        }
        return overrides
    }

    static func privacySettings(
        applying imported: RedactedPrivacySettings,
        to current: PrivacySettings
    ) -> PrivacySettings {
        var updated = current
        updated.collectionEnabled = imported.collectionEnabled
        updated.clipboardContextEnabled = imported.clipboardContextEnabled
        updated.screenContextEnabled = imported.screenContextEnabled
        updated.productivityMetricsEnabled = imported.productivityMetricsEnabled
        updated.perDomainRules = imported.domainRules
        updated.telemetryEnabled = false
        return updated
    }

    static func backendSettings(
        applying imported: RedactedBackendSettings,
        to current: CompletionBackendSettings
    ) -> CompletionBackendSettings {
        var updated = current
        updated.engineKind = imported.engineKind
        updated.remoteBaseURL = sanitizedRemoteBaseURL(imported.remoteBaseURL)
        updated.remoteModel = imported.remoteModel
        updated.localMaxRAMBytes = imported.localMaxRAMBytes
        updated.fallbackToRemoteOnLocalFailure = imported.fallbackToRemoteOnLocalFailure
        updated.fallbackToRemoteOnAppleIntelligenceFailure = imported.fallbackToRemoteOnAppleIntelligenceFailure
        updated.multiSuggestionEnabled = imported.multiSuggestionEnabled
        updated.stopSequences = imported.stopSequences
        return updated
    }

    private static func localModelBasename(from path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }
        let basename = URL(fileURLWithPath: trimmed).lastPathComponent
        return basename.isEmpty ? nil : basename
    }

    private static func sanitizedRemoteBaseURL(_ rawValue: String) -> String {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              components.scheme != nil,
              components.host != nil else {
            if trimmed.contains("@") || trimmed.contains("?") || trimmed.contains("#") {
                return "[redacted endpoint]"
            }
            return trimmed
        }

        components.user = nil
        components.password = nil
        components.query = nil
        components.fragment = nil
        return components.string ?? "[redacted endpoint]"
    }

    private static func privacySourceSummary(_ settings: PrivacySettings) -> String {
        [
            "collection \(settings.collectionEnabled ? "on" : "off")",
            "clipboard \(settings.clipboardContextEnabled ? "on" : "off")",
            "screen \(settings.screenContextEnabled ? "on" : "off")",
            "metrics \(settings.productivityMetricsEnabled ? "on" : "off")"
        ].joined(separator: ", ")
    }

    private static func privacySourceSummary(_ settings: RedactedPrivacySettings) -> String {
        [
            "collection \(settings.collectionEnabled ? "on" : "off")",
            "clipboard \(settings.clipboardContextEnabled ? "on" : "off")",
            "screen \(settings.screenContextEnabled ? "on" : "off")",
            "metrics \(settings.productivityMetricsEnabled ? "on" : "off")"
        ].joined(separator: ", ")
    }

    private static func shortcutSummary(_ settings: KeyboardShortcutSettings) -> String {
        KeyboardShortcutCommand.allCases
            .map { "\($0.rawValue)=\(settings[$0].displayName)" }
            .joined(separator: ", ")
    }

    private static func backendSummary(_ settings: CompletionBackendSettings) -> String {
        "\(settings.engineKind.rawValue), \(settings.remoteModel) at \(settings.remoteBaseURL)"
    }

    private static func backendSummary(_ settings: RedactedBackendSettings) -> String {
        "\(settings.engineKind.rawValue), \(settings.remoteModel) at \(settings.remoteBaseURL)"
    }
}
