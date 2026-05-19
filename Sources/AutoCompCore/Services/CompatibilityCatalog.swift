import Foundation

public struct CompatibilityDecision: Equatable, Sendable {
    public let profile: AppCompatibilityProfile
    public let mode: SuggestionDisplayMode
    public let enabled: Bool
    public let setupMessage: String?

    public init(
        profile: AppCompatibilityProfile,
        mode: SuggestionDisplayMode,
        enabled: Bool,
        setupMessage: String? = nil
    ) {
        self.profile = profile
        self.mode = mode
        self.enabled = enabled
        self.setupMessage = setupMessage
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
        userEnabledOverrides: [String: Bool] = [:]
    ) -> CompatibilityDecision {
        var profile = profile(for: bundleID)

        if let domain, Self.unsupportedGoogleWorkspaceDomains.contains(where: domain.contains) {
            profile = AppCompatibilityProfile(
                bundleID: bundleID,
                displayName: profile.displayName,
                status: .unsupported,
                defaultMode: .disabled,
                domains: [domain],
                notes: "Google Sheets and Slides are unsupported in the MVP.",
                enabledByDefault: false
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
                enabledByDefault: profile.enabledByDefault
            )
        }

        let enabled = userEnabledOverrides[profile.bundleID] ?? profile.enabledByDefault
        let mode = enabled ? profile.defaultMode : .disabled
        let setupMessage = profile.requiresSetup ? profile.notes : nil

        return CompatibilityDecision(profile: profile, mode: mode, enabled: enabled, setupMessage: setupMessage)
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
        AppCompatibilityProfile(bundleID: "com.apple.mail", displayName: "Mail", status: .works, defaultMode: .inline),
        AppCompatibilityProfile(bundleID: "com.apple.MobileSMS", displayName: "Messages", status: .partial, defaultMode: .inline),
        AppCompatibilityProfile(bundleID: "com.apple.Safari", displayName: "Safari", status: .works, defaultMode: .inline),
        AppCompatibilityProfile(bundleID: "com.google.Chrome", displayName: "Chrome", status: .works, defaultMode: .inline),
        AppCompatibilityProfile(bundleID: "com.brave.Browser", displayName: "Brave", status: .works, defaultMode: .inline),
        AppCompatibilityProfile(bundleID: "com.microsoft.edgemac", displayName: "Microsoft Edge", status: .works, defaultMode: .inline),
        AppCompatibilityProfile(bundleID: "company.thebrowser.Browser", displayName: "Arc", status: .setupNeeded, defaultMode: .inline, requiresSetup: true, notes: "Inline support may require browser accessibility setup."),
        AppCompatibilityProfile(bundleID: "company.thebrowser.dia", displayName: "Dia", status: .setupNeeded, defaultMode: .inline, requiresSetup: true, notes: "Inline support may require browser accessibility setup."),
        AppCompatibilityProfile(bundleID: "org.mozilla.firefox", displayName: "Firefox", status: .mirrorOnly, defaultMode: .mirrorWindow, notes: "Firefox is mirror-window only for the MVP."),
        AppCompatibilityProfile(bundleID: "app.zen-browser.zen", displayName: "Zen Browser", status: .mirrorOnly, defaultMode: .mirrorWindow, notes: "Zen Browser is mirror-window only for the MVP."),
        AppCompatibilityProfile(bundleID: "com.microsoft.Word", displayName: "Microsoft Word", status: .works, defaultMode: .inline),
        AppCompatibilityProfile(bundleID: "com.microsoft.Outlook", displayName: "Outlook", status: .works, defaultMode: .inline),
        AppCompatibilityProfile(bundleID: "com.mimestream.Mimestream", displayName: "Mimestream", status: .works, defaultMode: .inline),
        AppCompatibilityProfile(bundleID: "notion.id", displayName: "Notion", status: .works, defaultMode: .inline),
        AppCompatibilityProfile(bundleID: "md.obsidian", displayName: "Obsidian", status: .works, defaultMode: .inline),
        AppCompatibilityProfile(bundleID: "com.microsoft.teams2", displayName: "Microsoft Teams", status: .partial, defaultMode: .inline),
        AppCompatibilityProfile(bundleID: "net.whatsapp.WhatsApp", displayName: "WhatsApp", status: .partial, defaultMode: .inline),
        AppCompatibilityProfile(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack", status: .partial, defaultMode: .mirrorWindow, notes: "Slack support is partial in the MVP."),
        AppCompatibilityProfile(bundleID: "com.apple.Terminal", displayName: "Terminal", status: .partial, defaultMode: .mirrorWindow, notes: "Terminal completions are selective and can be force-activated."),
        AppCompatibilityProfile(bundleID: "com.googlecode.iterm2", displayName: "iTerm", status: .partial, defaultMode: .mirrorWindow, notes: "iTerm completions are selective and can be force-activated."),
        AppCompatibilityProfile(bundleID: "com.microsoft.VSCode", displayName: "VS Code", status: .partial, defaultMode: .disabled, notes: "Code editors are disabled by default; enable only for chat/sidebar panes.", enabledByDefault: false),
        AppCompatibilityProfile(bundleID: "com.todesktop.230313mzl4w4u92", displayName: "Cursor", status: .partial, defaultMode: .disabled, notes: "Code editors are disabled by default; enable only for chat/sidebar panes.", enabledByDefault: false),
        AppCompatibilityProfile(bundleID: "com.exafunction.windsurf", displayName: "Windsurf", status: .partial, defaultMode: .disabled, notes: "Code editors are disabled by default; enable only for chat/sidebar panes.", enabledByDefault: false),
        AppCompatibilityProfile(bundleID: "org.mozilla.thunderbird", displayName: "Thunderbird", status: .unsupported, defaultMode: .disabled, notes: "Unsupported unless its accessibility behavior changes.", enabledByDefault: false),
        AppCompatibilityProfile(bundleID: "com.apple.iWork.Pages", displayName: "Pages", status: .unsupported, defaultMode: .disabled, notes: "Unsupported unless sufficient text-field accessibility is exposed.", enabledByDefault: false),
        AppCompatibilityProfile(bundleID: "com.literatureandlatte.scrivener3", displayName: "Scrivener", status: .unsupported, defaultMode: .disabled, notes: "Unsupported unless sufficient text-field accessibility is exposed.", enabledByDefault: false),
        AppCompatibilityProfile(bundleID: "com.microsoft.onenote.mac", displayName: "OneNote", status: .unsupported, defaultMode: .disabled, enabledByDefault: false),
        AppCompatibilityProfile(bundleID: "com.mitchellh.ghostty", displayName: "Ghostty", status: .unsupported, defaultMode: .disabled, enabledByDefault: false),
        AppCompatibilityProfile(bundleID: "dev.warp.Warp-Stable", displayName: "Warp", status: .unsupported, defaultMode: .disabled, enabledByDefault: false)
    ]
}
