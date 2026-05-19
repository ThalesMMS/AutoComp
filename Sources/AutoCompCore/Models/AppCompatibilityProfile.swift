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

public struct AppCompatibilityProfile: Identifiable, Codable, Equatable, Sendable {
    public var id: String { bundleID }

    public let bundleID: String
    public let displayName: String
    public let status: CompatibilityStatus
    public let defaultMode: SuggestionDisplayMode
    public let requiresSetup: Bool
    public let domains: [String]
    public let notes: String
    public let enabledByDefault: Bool

    public init(
        bundleID: String,
        displayName: String,
        status: CompatibilityStatus,
        defaultMode: SuggestionDisplayMode,
        requiresSetup: Bool = false,
        domains: [String] = [],
        notes: String = "",
        enabledByDefault: Bool = true
    ) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.status = status
        self.defaultMode = defaultMode
        self.requiresSetup = requiresSetup
        self.domains = domains
        self.notes = notes
        self.enabledByDefault = enabledByDefault
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
