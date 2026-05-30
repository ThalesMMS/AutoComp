import Foundation

public struct CompatibilityDecision: Equatable, Sendable {
    public enum RuleSource: String, Codable, Equatable, Sendable {
        case `default` = "default"
        case appRule = "app-rule"
        case domainRule = "domain-rule"
    }

    public let profile: AppCompatibilityProfile
    public let mode: SuggestionDisplayMode
    public let enabled: Bool
    public let overrideMode: CompatibilityOverrideMode
    public let allowsAutomaticSuggestions: Bool
    public let setupMessage: String?
    public let warningMessage: String?
    public let ruleSource: RuleSource

    public init(
        profile: AppCompatibilityProfile,
        mode: SuggestionDisplayMode,
        enabled: Bool,
        overrideMode: CompatibilityOverrideMode = .automatic,
        allowsAutomaticSuggestions: Bool = true,
        setupMessage: String? = nil,
        warningMessage: String? = nil,
        ruleSource: RuleSource = .default
    ) {
        self.profile = profile
        self.mode = mode
        self.enabled = enabled
        self.overrideMode = overrideMode
        self.allowsAutomaticSuggestions = allowsAutomaticSuggestions
        self.setupMessage = setupMessage
        self.warningMessage = warningMessage
        self.ruleSource = ruleSource
    }
}

public struct CompatibilityCatalog: Sendable {
    public let profiles: [AppCompatibilityProfile]

    public init(profiles: [AppCompatibilityProfile] = CompatibilityCatalog.defaultProfiles) {
        self.profiles = profiles
    }

    public func profile(for bundleID: String) -> AppCompatibilityProfile {
        profiles.first { $0.bundleID == bundleID } ?? AppCompatibilityProfile(
            bundleID: bundleID,
            displayName: "Unknown app",
            status: .partial,
            defaultMode: .inline,
            notes: "No explicit profile. AutoComp will try inline suggestions when the app exposes text-field geometry."
        )
    }

    public func decision(
        bundleID: String,
        domain: String?,
        userEnabledOverrides: [String: Bool] = [:],
        userModeOverrides: [String: CompatibilityOverrideMode] = [:]
    ) -> CompatibilityDecision {
        var profile = profile(for: bundleID)
        let hostCategory = RiskyHostAppPolicy.category(bundleID: bundleID, domain: domain)

        if let domain, Self.unsupportedGoogleWorkspaceDomains.contains(where: domain.contains) {
            profile = AppCompatibilityProfile(
                bundleID: bundleID,
                displayName: profile.displayName,
                status: .unsupported,
                defaultMode: .disabled,
                domains: [domain],
                notes: "Google Sheets and Slides are unsupported in the MVP.",
                defaultActivationMode: .disabled
            )
        } else if let domain, domain.contains("docs.google.com") {
            profile = AppCompatibilityProfile(
                bundleID: bundleID,
                displayName: profile.displayName,
                status: .setupNeeded,
                defaultMode: .inline,
                requiresSetup: true,
                domains: [domain],
                notes: "Enable screen reader support and braille support in Google Docs, and disable Smart Compose.",
                defaultActivationMode: profile.defaultActivationMode
            )
        } else if let domain, hostCategory == .chat {
            profile = AppCompatibilityProfile(
                bundleID: bundleID,
                displayName: profile.displayName,
                status: .partial,
                defaultMode: .inline,
                domains: [domain],
                notes: "Manual trigger only by default to avoid sending chat messages.",
                defaultActivationMode: .manualOnly
            )
        }

        let defaultOverrideMode = profile.defaultActivationMode
        let legacyOverrideMode = userEnabledOverrides[profile.bundleID].map { $0 ? CompatibilityOverrideMode.automatic : .disabled }
        let domainOverrideMode = domain.flatMap { Self.modeOverride(forDomain: $0, in: userModeOverrides) }
        let appOverrideMode = userModeOverrides[profile.bundleID]
        let explicitOverrideMode = domainOverrideMode ?? appOverrideMode
        let ruleSource: CompatibilityDecision.RuleSource
        if domainOverrideMode != nil {
            ruleSource = .domainRule
        } else if appOverrideMode != nil || legacyOverrideMode != nil {
            ruleSource = .appRule
        } else {
            ruleSource = .default
        }
        var overrideMode = explicitOverrideMode ?? legacyOverrideMode ?? defaultOverrideMode
        var riskWarning: String?
        if hostCategory == .terminal {
            if explicitOverrideMode == .automatic {
                riskWarning = "Warning: automatic terminal suggestions can execute commands. Prefer Manual only unless this override is intentional."
            } else if legacyOverrideMode == .automatic {
                overrideMode = .manualOnly
                riskWarning = "Terminal enablement defaults to Manual only unless Automatic is selected explicitly."
            }
        }
        let enabled = profile.status != .unsupported && overrideMode != .disabled
        let defaultDisplayMode = profile.defaultMode == .disabled && enabled ? SuggestionDisplayMode.inline : profile.defaultMode
        let mode = enabled ? defaultDisplayMode : .disabled
        let allowsAutomaticSuggestions = enabled && overrideMode == .automatic
        let setupMessage = profile.requiresSetup ? profile.notes : nil

        return CompatibilityDecision(
            profile: profile,
            mode: mode,
            enabled: enabled,
            overrideMode: overrideMode,
            allowsAutomaticSuggestions: allowsAutomaticSuggestions,
            setupMessage: setupMessage,
            warningMessage: riskWarning,
            ruleSource: ruleSource
        )
    }

    public static func overrideKey(forDomain domain: String) -> String {
        let normalized = DomainNormalization.canonicalDomainStringAllowingEmpty(from: domain)
        return "domain:\(normalized)"
    }

    private static func modeOverride(
        forDomain domain: String,
        in overrides: [String: CompatibilityOverrideMode]
    ) -> CompatibilityOverrideMode? {
        for candidate in domainOverrideCandidates(for: domain) {
            if let override = overrides[candidate] {
                return override
            }
        }
        return nil
    }

    private static func domainOverrideCandidates(for domain: String) -> [String] {
        DomainNormalization
            .specificityCandidates(for: domain)
            .map(overrideKey(forDomain:))
    }
}

public extension CompatibilityCatalog {
    static let unsupportedGoogleWorkspaceDomains = [
        "docs.google.com/spreadsheets",
        "docs.google.com/presentation"
    ]

    static let defaultProfiles: [AppCompatibilityProfile] = [
        AppCompatibilityProfile(bundleID: "com.apple.TextEdit", displayName: "TextEdit", status: .works, defaultMode: .inline),
        AppCompatibilityProfile(bundleID: "com.apple.Notes", displayName: "Notes", status: .works, defaultMode: .inline),
        AppCompatibilityProfile(bundleID: "com.apple.mail", displayName: "Mail", status: .works, defaultMode: .inline, notes: "Manual trigger only by default to avoid interrupting compose flows.", defaultActivationMode: .manualOnly),
        AppCompatibilityProfile(bundleID: "com.apple.MobileSMS", displayName: "Messages", status: .partial, defaultMode: .inline, notes: "Manual trigger only by default to avoid interrupting chat flows.", defaultActivationMode: .manualOnly),
        AppCompatibilityProfile(bundleID: "com.apple.Safari", displayName: "Safari", status: .works, defaultMode: .inline),
        AppCompatibilityProfile(bundleID: "com.google.Chrome", displayName: "Chrome", status: .works, defaultMode: .inline),
        AppCompatibilityProfile(bundleID: "com.brave.Browser", displayName: "Brave", status: .works, defaultMode: .inline),
        AppCompatibilityProfile(bundleID: "com.microsoft.edgemac", displayName: "Microsoft Edge", status: .works, defaultMode: .inline),
        AppCompatibilityProfile(bundleID: "company.thebrowser.Browser", displayName: "Arc", status: .setupNeeded, defaultMode: .inline, requiresSetup: true, notes: "Inline support may require browser accessibility setup."),
        AppCompatibilityProfile(bundleID: "company.thebrowser.dia", displayName: "Dia", status: .setupNeeded, defaultMode: .inline, requiresSetup: true, notes: "Inline support may require browser accessibility setup."),
        AppCompatibilityProfile(bundleID: "org.mozilla.firefox", displayName: "Firefox", status: .mirrorOnly, defaultMode: .mirrorWindow, notes: "Firefox is mirror-window only for the MVP."),
        AppCompatibilityProfile(bundleID: "app.zen-browser.zen", displayName: "Zen Browser", status: .mirrorOnly, defaultMode: .mirrorWindow, notes: "Zen Browser is mirror-window only for the MVP."),
        AppCompatibilityProfile(bundleID: "com.microsoft.Word", displayName: "Microsoft Word", status: .works, defaultMode: .inline),
        AppCompatibilityProfile(bundleID: "com.microsoft.Outlook", displayName: "Outlook", status: .works, defaultMode: .inline, notes: "Manual trigger only by default to avoid interrupting compose flows.", defaultActivationMode: .manualOnly),
        AppCompatibilityProfile(bundleID: "com.mimestream.Mimestream", displayName: "Mimestream", status: .works, defaultMode: .inline, notes: "Manual trigger only by default to avoid interrupting compose flows.", defaultActivationMode: .manualOnly),
        AppCompatibilityProfile(bundleID: "notion.id", displayName: "Notion", status: .works, defaultMode: .inline),
        AppCompatibilityProfile(bundleID: "md.obsidian", displayName: "Obsidian", status: .works, defaultMode: .inline),
        AppCompatibilityProfile(bundleID: "com.microsoft.teams2", displayName: "Microsoft Teams", status: .partial, defaultMode: .inline, notes: "Manual trigger only by default to avoid interrupting chat flows.", defaultActivationMode: .manualOnly),
        AppCompatibilityProfile(bundleID: "net.whatsapp.WhatsApp", displayName: "WhatsApp", status: .partial, defaultMode: .inline, notes: "Manual trigger only by default to avoid interrupting chat flows.", defaultActivationMode: .manualOnly),
        AppCompatibilityProfile(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack", status: .partial, defaultMode: .mirrorWindow, notes: "Manual trigger only by default; Slack support is partial in the MVP.", defaultActivationMode: .manualOnly),
        AppCompatibilityProfile(bundleID: "com.hnc.Discord", displayName: "Discord", status: .partial, defaultMode: .mirrorWindow, notes: "Manual trigger only by default; Discord support is partial in the MVP.", defaultActivationMode: .manualOnly),
        AppCompatibilityProfile(bundleID: "com.hnc.DiscordPTB", displayName: "Discord PTB", status: .partial, defaultMode: .mirrorWindow, notes: "Manual trigger only by default; Discord support is partial in the MVP.", defaultActivationMode: .manualOnly),
        AppCompatibilityProfile(bundleID: "com.hnc.DiscordCanary", displayName: "Discord Canary", status: .partial, defaultMode: .mirrorWindow, notes: "Manual trigger only by default; Discord support is partial in the MVP.", defaultActivationMode: .manualOnly),
        AppCompatibilityProfile(bundleID: "ru.keepcoder.Telegram", displayName: "Telegram", status: .partial, defaultMode: .inline, notes: "Manual trigger only by default to avoid interrupting chat flows.", defaultActivationMode: .manualOnly),
        AppCompatibilityProfile(bundleID: "com.tdesktop.Telegram", displayName: "Telegram Desktop", status: .partial, defaultMode: .inline, notes: "Manual trigger only by default to avoid interrupting chat flows.", defaultActivationMode: .manualOnly),
        AppCompatibilityProfile(bundleID: "com.apple.Terminal", displayName: "Terminal", status: .partial, defaultMode: .mirrorWindow, notes: "Terminal completions are disabled by default and require an explicit override.", defaultActivationMode: .disabled),
        AppCompatibilityProfile(bundleID: "com.googlecode.iterm2", displayName: "iTerm", status: .partial, defaultMode: .mirrorWindow, notes: "iTerm completions are disabled by default and require an explicit override.", defaultActivationMode: .disabled),
        AppCompatibilityProfile(bundleID: "com.github.wez.wezterm", displayName: "WezTerm", status: .partial, defaultMode: .mirrorWindow, notes: "Terminal completions are disabled by default and require an explicit override.", defaultActivationMode: .disabled),
        AppCompatibilityProfile(bundleID: "org.alacritty", displayName: "Alacritty", status: .partial, defaultMode: .mirrorWindow, notes: "Terminal completions are disabled by default and require an explicit override.", defaultActivationMode: .disabled),
        AppCompatibilityProfile(bundleID: "com.microsoft.VSCode", displayName: "VS Code", status: .partial, defaultMode: .inline, notes: "Code editors are disabled by default; enable only for chat/sidebar panes.", enabledByDefault: false),
        AppCompatibilityProfile(bundleID: "com.todesktop.230313mzl4w4u92", displayName: "Cursor", status: .partial, defaultMode: .inline, notes: "Code editors are disabled by default; enable only for chat/sidebar panes.", enabledByDefault: false),
        AppCompatibilityProfile(bundleID: "com.exafunction.windsurf", displayName: "Windsurf", status: .partial, defaultMode: .inline, notes: "Code editors are disabled by default; enable only for chat/sidebar panes.", enabledByDefault: false),
        AppCompatibilityProfile(bundleID: "com.apple.dt.Xcode", displayName: "Xcode", status: .partial, defaultMode: .inline, notes: "Code editors are disabled by default; enable only for chat/sidebar panes.", enabledByDefault: false),
        AppCompatibilityProfile(bundleID: "com.jetbrains.intellij", displayName: "IntelliJ IDEA", status: .partial, defaultMode: .inline, notes: "Code editors are disabled by default; enable only for chat/sidebar panes.", enabledByDefault: false),
        AppCompatibilityProfile(bundleID: "com.jetbrains.pycharm", displayName: "PyCharm", status: .partial, defaultMode: .inline, notes: "Code editors are disabled by default; enable only for chat/sidebar panes.", enabledByDefault: false),
        AppCompatibilityProfile(bundleID: "com.jetbrains.WebStorm", displayName: "WebStorm", status: .partial, defaultMode: .inline, notes: "Code editors are disabled by default; enable only for chat/sidebar panes.", enabledByDefault: false),
        AppCompatibilityProfile(bundleID: "com.jetbrains.CLion", displayName: "CLion", status: .partial, defaultMode: .inline, notes: "Code editors are disabled by default; enable only for chat/sidebar panes.", enabledByDefault: false),
        AppCompatibilityProfile(bundleID: "com.jetbrains.goland", displayName: "GoLand", status: .partial, defaultMode: .inline, notes: "Code editors are disabled by default; enable only for chat/sidebar panes.", enabledByDefault: false),
        AppCompatibilityProfile(bundleID: "com.jetbrains.rubymine", displayName: "RubyMine", status: .partial, defaultMode: .inline, notes: "Code editors are disabled by default; enable only for chat/sidebar panes.", enabledByDefault: false),
        AppCompatibilityProfile(bundleID: "com.jetbrains.PhpStorm", displayName: "PhpStorm", status: .partial, defaultMode: .inline, notes: "Code editors are disabled by default; enable only for chat/sidebar panes.", enabledByDefault: false),
        AppCompatibilityProfile(bundleID: "com.jetbrains.rider", displayName: "Rider", status: .partial, defaultMode: .inline, notes: "Code editors are disabled by default; enable only for chat/sidebar panes.", enabledByDefault: false),
        AppCompatibilityProfile(bundleID: "com.jetbrains.datagrip", displayName: "DataGrip", status: .partial, defaultMode: .inline, notes: "Code editors are disabled by default; enable only for chat/sidebar panes.", enabledByDefault: false),
        AppCompatibilityProfile(bundleID: "org.mozilla.thunderbird", displayName: "Thunderbird", status: .unsupported, defaultMode: .disabled, notes: "Unsupported unless its accessibility behavior changes.", enabledByDefault: false),
        AppCompatibilityProfile(bundleID: "com.apple.iWork.Pages", displayName: "Pages", status: .unsupported, defaultMode: .disabled, notes: "Unsupported unless sufficient text-field accessibility is exposed.", enabledByDefault: false),
        AppCompatibilityProfile(bundleID: "com.literatureandlatte.scrivener3", displayName: "Scrivener", status: .unsupported, defaultMode: .disabled, notes: "Unsupported unless sufficient text-field accessibility is exposed.", enabledByDefault: false),
        AppCompatibilityProfile(bundleID: "com.microsoft.onenote.mac", displayName: "OneNote", status: .unsupported, defaultMode: .disabled, enabledByDefault: false),
        AppCompatibilityProfile(bundleID: "com.mitchellh.ghostty", displayName: "Ghostty", status: .unsupported, defaultMode: .disabled, enabledByDefault: false),
        AppCompatibilityProfile(bundleID: "dev.warp.Warp-Stable", displayName: "Warp", status: .unsupported, defaultMode: .disabled, enabledByDefault: false)
    ]
}
