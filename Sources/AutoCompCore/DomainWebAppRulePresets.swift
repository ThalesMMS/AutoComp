import Foundation

/// Built-in catalog of web-app presets that can expand into one or more domain rules.
///
/// Presets are intended for UI-driven "one click" installation. The actual rule matching is still
/// host-based and uses the expanded `DomainPattern`s.
public struct DomainWebAppRulePreset: Codable, Sendable, Equatable, Identifiable {
    public var id: String
    public var title: String
    public var description: String

    /// The host patterns created for this preset.
    public var patterns: [DomainPattern]

    /// The default action to apply when the preset is installed.
    public var defaultAction: DomainWebAppRuleAction

    public init(
        id: String,
        title: String,
        description: String,
        patterns: [DomainPattern],
        defaultAction: DomainWebAppRuleAction
    ) {
        self.id = id
        self.title = title
        self.description = description
        self.patterns = patterns
        self.defaultAction = defaultAction
    }

    public func makeRules(
        actionOverride: DomainWebAppRuleAction? = nil,
        now: Date = Date()
    ) -> [DomainWebAppRule] {
        let action = actionOverride ?? defaultAction
        return patterns.map { pattern in
            DomainWebAppRule(
                pattern: pattern,
                presetId: id,
                action: action,
                createdAt: now,
                updatedAt: now
            )
        }
    }
}

public enum DomainWebAppRulePresetCatalog {
    // Stable identifiers for persistence.
    public enum PresetId {
        public static let googleDocs = "google-docs"
        public static let googleSheets = "google-sheets"
        public static let googleSlides = "google-slides"
        public static let emailWebApps = "email-web-apps"
        public static let sensitiveOrUnsupported = "sensitive-or-unsupported"
    }

    public static let all: [DomainWebAppRulePreset] = [
        DomainWebAppRulePreset(
            id: PresetId.googleDocs,
            title: "Google Docs",
            description: "Improve reliability on Google Docs by requiring visual context.",
            patterns: [
                .exactHost("docs.google.com"),
                .wildcardSubdomains("docs.google.com")
            ],
            defaultAction: .visualContextRequired
        ),
        DomainWebAppRulePreset(
            id: PresetId.googleSheets,
            title: "Google Sheets",
            description: "Improve reliability on Google Sheets by requiring visual context.",
            patterns: [
                .exactHost("sheets.google.com"),
                .wildcardSubdomains("sheets.google.com")
            ],
            defaultAction: .visualContextRequired
        ),
        DomainWebAppRulePreset(
            id: PresetId.googleSlides,
            title: "Google Slides",
            description: "Improve reliability on Google Slides by requiring visual context.",
            patterns: [
                .exactHost("slides.google.com"),
                .wildcardSubdomains("slides.google.com")
            ],
            defaultAction: .visualContextRequired
        ),
        DomainWebAppRulePreset(
            id: PresetId.emailWebApps,
            title: "Email Web Apps",
            description: "Limit autocomplete to manual-only mode on common email web apps.",
            patterns: [
                .exactHost("mail.google.com"),
                .wildcardSubdomains("mail.google.com"),
                .exactHost("outlook.office.com"),
                .wildcardSubdomains("outlook.office.com"),
                .exactHost("outlook.live.com"),
                .wildcardSubdomains("outlook.live.com"),
                .exactHost("mail.yahoo.com"),
                .wildcardSubdomains("mail.yahoo.com"),
                .exactHost("proton.me"),
                .wildcardSubdomains("proton.me"),
                .exactHost("protonmail.com"),
                .wildcardSubdomains("protonmail.com")
            ],
            defaultAction: .manualOnly
        ),
        DomainWebAppRulePreset(
            id: PresetId.sensitiveOrUnsupported,
            title: "Sensitive / Unsupported Sites",
            description: "Disable autocomplete on common sensitive sites (banking, identity, passwords).",
            patterns: [
                .exactHost("1password.com"),
                .wildcardSubdomains("1password.com"),
                .exactHost("lastpass.com"),
                .wildcardSubdomains("lastpass.com"),
                .exactHost("bitwarden.com"),
                .wildcardSubdomains("bitwarden.com"),
                .exactHost("vault.bitwarden.com"),

                .exactHost("paypal.com"),
                .wildcardSubdomains("paypal.com"),
                .exactHost("chase.com"),
                .wildcardSubdomains("chase.com"),
                .exactHost("bankofamerica.com"),
                .wildcardSubdomains("bankofamerica.com"),
                .exactHost("wellsfargo.com"),
                .wildcardSubdomains("wellsfargo.com"),

                .exactHost("id.me"),
                .wildcardSubdomains("id.me"),
                .exactHost("login.gov"),
                .wildcardSubdomains("login.gov")
            ],
            defaultAction: .deny
        )
    ]

    public static func preset(id: String) -> DomainWebAppRulePreset? {
        all.first(where: { $0.id == id })
    }
}

public extension DomainWebAppRuleset {
    /// Convenience for installing a preset into a ruleset.
    mutating func installPreset(
        id: String,
        actionOverride: DomainWebAppRuleAction? = nil,
        now: Date = Date()
    ) {
        guard let preset = DomainWebAppRulePresetCatalog.preset(id: id) else { return }
        rules.append(contentsOf: preset.makeRules(actionOverride: actionOverride, now: now))
    }
}
