import Foundation

/// Domain and web-app rule definitions used to gate autocomplete behavior.
///
/// These models are deliberately **host-based**: matching should be performed on a normalized host
/// (and optionally a coarse app-specific host pattern), never on full URLs, paths, or user content.
public enum DomainWebAppRuleAction: String, Codable, Sendable {
    /// Autocomplete can activate normally.
    case allow

    /// Autocomplete should never activate.
    case deny

    /// Autocomplete can run only when explicitly invoked (no automatic activation).
    case manualOnly

    /// Autocomplete can activate only when the app can obtain the required visual context signals.
    case visualContextRequired
}

/// The kind of target a rule applies to.
///
/// - Note: This is distinct from the UI "preset" concept. Presets can expand into multiple
///   `DomainWebAppRule` entries and are tracked via `presetId`.
public enum DomainWebAppRuleTarget: Codable, Sendable, Equatable {
    /// A specific domain pattern.
    case domain(DomainPattern)

    /// A logical web-app preset (e.g., "Google Docs") that expands into one or more domain patterns.
    ///
    /// This is stored for provenance; matching is still evaluated using the expanded domain patterns.
    case preset(id: String)
}

/// A single persisted rule entry.
public struct DomainWebAppRule: Codable, Sendable, Identifiable, Equatable {
    public var id: UUID
    public var isEnabled: Bool

    /// A pattern string used for matching (host only; may be exact or wildcard).
    public var pattern: DomainPattern

    /// Optional source preset identifier (if created from a preset install flow).
    public var presetId: String?

    public var action: DomainWebAppRuleAction

    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: UUID = UUID(),
        isEnabled: Bool = true,
        pattern: DomainPattern,
        presetId: String? = nil,
        action: DomainWebAppRuleAction,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.isEnabled = isEnabled
        self.pattern = pattern
        self.presetId = presetId
        self.action = action
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// A container for persisted rule sets with explicit schema versioning.
public struct DomainWebAppRuleset: Codable, Sendable, Equatable {
    public static let currentSchemaVersion: Int = 1

    public var schemaVersion: Int
    public var rules: [DomainWebAppRule]

    public init(schemaVersion: Int = DomainWebAppRuleset.currentSchemaVersion, rules: [DomainWebAppRule]) {
        self.schemaVersion = schemaVersion
        self.rules = rules
    }
}

/// Convenience wrapper used by app settings.
public struct DomainWebAppRules: Codable, Sendable, Equatable {
    public var ruleset: DomainWebAppRuleset

    public init(ruleset: DomainWebAppRuleset = DomainWebAppRuleset(rules: [])) {
        self.ruleset = ruleset
    }
}
