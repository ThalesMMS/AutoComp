import Foundation

public enum CompatibilityStatus: String, Codable, CaseIterable, Sendable {
    case works
    case setupNeeded
    case partial
    case mirrorOnly
    case unsupported
}

public enum SuggestionDisplayMode: String, Codable, CaseIterable, Sendable {
    case inline
    case mirrorWindow
    case disabled
}

public enum SuggestionActivationMode: String, Codable, CaseIterable, Sendable, Identifiable {
    case automatic
    case manualOnly
    case disabled

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .automatic:
            return "Automatic"
        case .manualOnly:
            return "Manual only"
        case .disabled:
            return "Disabled"
        }
    }

    public var helpText: String {
        switch self {
        case .automatic:
            return "Autocomplete can activate automatically while you type."
        case .manualOnly:
            return "Autocomplete will not activate automatically. Use the manual trigger shortcut to request suggestions."
        case .disabled:
            return "Autocomplete is turned off for this target."
        }
    }
}

public typealias CompatibilityOverrideMode = SuggestionActivationMode

public struct AppCompatibilityProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: String { bundleID }

    public let bundleID: String
    public let displayName: String
    public let status: CompatibilityStatus
    public let defaultMode: SuggestionDisplayMode
    public let requiresSetup: Bool
    public let domains: [String]
    public let notes: String
    public let defaultActivationMode: SuggestionActivationMode
    public var enabledByDefault: Bool { defaultActivationMode != .disabled }

    public init(
        bundleID: String,
        displayName: String,
        status: CompatibilityStatus,
        defaultMode: SuggestionDisplayMode,
        requiresSetup: Bool = false,
        domains: [String] = [],
        notes: String = "",
        enabledByDefault: Bool = true,
        defaultActivationMode: SuggestionActivationMode? = nil
    ) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.status = status
        self.defaultMode = defaultMode
        self.requiresSetup = requiresSetup
        self.domains = domains
        self.notes = notes
        self.defaultActivationMode = defaultActivationMode ?? (enabledByDefault ? .automatic : .disabled)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        bundleID = try container.decode(String.self, forKey: .bundleID)
        displayName = try container.decode(String.self, forKey: .displayName)
        status = try container.decode(CompatibilityStatus.self, forKey: .status)
        defaultMode = try container.decode(SuggestionDisplayMode.self, forKey: .defaultMode)
        requiresSetup = try container.decodeIfPresent(Bool.self, forKey: .requiresSetup) ?? false
        domains = try container.decodeIfPresent([String].self, forKey: .domains) ?? []
        notes = try container.decodeIfPresent(String.self, forKey: .notes) ?? ""

        let legacyEnabled = try container.decodeIfPresent(Bool.self, forKey: .enabledByDefault) ?? true
        defaultActivationMode = try container.decodeIfPresent(
            SuggestionActivationMode.self,
            forKey: .defaultActivationMode
        ) ?? (legacyEnabled ? .automatic : .disabled)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(bundleID, forKey: .bundleID)
        try container.encode(displayName, forKey: .displayName)
        try container.encode(status, forKey: .status)
        try container.encode(defaultMode, forKey: .defaultMode)
        try container.encode(requiresSetup, forKey: .requiresSetup)
        try container.encode(domains, forKey: .domains)
        try container.encode(notes, forKey: .notes)
        try container.encode(defaultActivationMode, forKey: .defaultActivationMode)
        try container.encode(enabledByDefault, forKey: .enabledByDefault)
    }

    private enum CodingKeys: String, CodingKey {
        case bundleID
        case displayName
        case status
        case defaultMode
        case requiresSetup
        case domains
        case notes
        case enabledByDefault
        case defaultActivationMode
    }
}

public struct AppIdentity: Codable, Equatable, Sendable {
    public let bundleID: String
    public let displayName: String
    public let processID: Int32

    public init(bundleID: String, displayName: String, processID: Int32) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.processID = processID
    }
}
