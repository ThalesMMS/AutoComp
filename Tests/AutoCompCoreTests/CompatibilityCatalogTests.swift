import AutoCompCore
import XCTest

final class CompatibilityCatalogTests: XCTestCase {
    func testCodeEditorsAreDisabledByDefault() {
        let catalog = CompatibilityCatalog()

        for bundleID in [
            "com.microsoft.VSCode",
            "com.todesktop.230313mzl4w4u92",
            "com.exafunction.windsurf",
            "com.apple.dt.Xcode",
            "com.jetbrains.intellij",
            "com.jetbrains.pycharm",
            "com.jetbrains.WebStorm",
            "com.jetbrains.CLion",
            "com.jetbrains.goland",
            "com.jetbrains.rubymine",
            "com.jetbrains.PhpStorm",
            "com.jetbrains.rider",
            "com.jetbrains.datagrip"
        ] {
            let decision = catalog.decision(bundleID: bundleID, domain: nil)

            XCTAssertFalse(decision.enabled, bundleID)
            XCTAssertEqual(decision.mode, .disabled, bundleID)
            XCTAssertEqual(decision.overrideMode, .disabled, bundleID)
            XCTAssertFalse(decision.allowsAutomaticSuggestions, bundleID)
            XCTAssertEqual(decision.profile.status, .partial, bundleID)
        }
    }

    func testWritingAppsAndMajorBrowsersUseAutomaticInlineDefaults() {
        let catalog = CompatibilityCatalog()

        for bundleID in [
            "com.apple.TextEdit",
            "com.apple.Notes",
            "com.apple.Safari",
            "com.google.Chrome",
            "com.brave.Browser",
            "com.microsoft.edgemac",
            "com.microsoft.Word",
            "notion.id",
            "md.obsidian"
        ] {
            let decision = catalog.decision(bundleID: bundleID, domain: nil)

            XCTAssertTrue(decision.enabled, bundleID)
            XCTAssertEqual(decision.mode, .inline, bundleID)
            XCTAssertEqual(decision.overrideMode, .automatic, bundleID)
            XCTAssertTrue(decision.allowsAutomaticSuggestions, bundleID)
        }
    }

    func testManualOnlyDefaultsForMailAndChatApps() {
        let catalog = CompatibilityCatalog()

        for bundleID in [
            "com.apple.mail",
            "com.microsoft.Outlook",
            "com.mimestream.Mimestream",
            "com.apple.MobileSMS",
            "com.microsoft.teams2",
            "net.whatsapp.WhatsApp",
            "ru.keepcoder.Telegram",
            "com.tdesktop.Telegram"
        ] {
            let decision = catalog.decision(bundleID: bundleID, domain: nil)

            XCTAssertTrue(decision.enabled, bundleID)
            XCTAssertEqual(decision.mode, .inline, bundleID)
            XCTAssertEqual(decision.overrideMode, .manualOnly, bundleID)
            XCTAssertFalse(decision.allowsAutomaticSuggestions, bundleID)
        }

        for bundleID in [
            "com.tinyspeck.slackmacgap",
            "com.hnc.Discord",
            "com.hnc.DiscordPTB",
            "com.hnc.DiscordCanary"
        ] {
            let decision = catalog.decision(bundleID: bundleID, domain: nil)

            XCTAssertTrue(decision.enabled, bundleID)
            XCTAssertEqual(decision.mode, .mirrorWindow, bundleID)
            XCTAssertEqual(decision.overrideMode, .manualOnly, bundleID)
            XCTAssertFalse(decision.allowsAutomaticSuggestions, bundleID)
        }
    }

    func testTerminalsAreDisabledByDefault() {
        let catalog = CompatibilityCatalog()

        for bundleID in [
            "com.apple.Terminal",
            "com.googlecode.iterm2",
            "com.github.wez.wezterm",
            "org.alacritty",
            "com.mitchellh.ghostty",
            "dev.warp.Warp-Stable"
        ] {
            let decision = catalog.decision(bundleID: bundleID, domain: nil)

            XCTAssertFalse(decision.enabled, bundleID)
            XCTAssertEqual(decision.mode, .disabled, bundleID)
            XCTAssertEqual(decision.overrideMode, .disabled, bundleID)
        }
    }

    func testTerminalEnablementIsManualOnlyUnlessAutomaticOverrideIsExplicit() {
        let catalog = CompatibilityCatalog()

        let legacyEnabled = catalog.decision(
            bundleID: "com.apple.Terminal",
            domain: nil,
            userEnabledOverrides: ["com.apple.Terminal": true]
        )
        XCTAssertTrue(legacyEnabled.enabled)
        XCTAssertEqual(legacyEnabled.mode, .mirrorWindow)
        XCTAssertEqual(legacyEnabled.overrideMode, .manualOnly)
        XCTAssertFalse(legacyEnabled.allowsAutomaticSuggestions)
        XCTAssertEqual(
            legacyEnabled.warningMessage,
            "Terminal enablement defaults to Manual only unless Automatic is selected explicitly."
        )
        XCTAssertNil(legacyEnabled.setupMessage)

        let manualOnly = catalog.decision(
            bundleID: "com.apple.Terminal",
            domain: nil,
            userModeOverrides: ["com.apple.Terminal": .manualOnly]
        )
        XCTAssertTrue(manualOnly.enabled)
        XCTAssertEqual(manualOnly.mode, .mirrorWindow)
        XCTAssertEqual(manualOnly.overrideMode, .manualOnly)
        XCTAssertFalse(manualOnly.allowsAutomaticSuggestions)
        XCTAssertNil(manualOnly.setupMessage)
        XCTAssertNil(manualOnly.warningMessage)

        let automatic = catalog.decision(
            bundleID: "com.apple.Terminal",
            domain: nil,
            userModeOverrides: ["com.apple.Terminal": .automatic]
        )
        XCTAssertTrue(automatic.enabled)
        XCTAssertEqual(automatic.mode, .mirrorWindow)
        XCTAssertEqual(automatic.overrideMode, .automatic)
        XCTAssertTrue(automatic.allowsAutomaticSuggestions)
        XCTAssertEqual(
            automatic.warningMessage,
            "Warning: automatic terminal suggestions can execute commands. Prefer Manual only unless this override is intentional."
        )
        XCTAssertNil(automatic.setupMessage)
    }

    func testBrowserChatDomainsUseManualOnlyCompatibility() {
        let decision = CompatibilityCatalog().decision(
            bundleID: "com.google.Chrome",
            domain: "https://chatgpt.com/c/example"
        )

        XCTAssertTrue(decision.enabled)
        XCTAssertEqual(decision.mode, .inline)
        XCTAssertEqual(decision.overrideMode, .manualOnly)
        XCTAssertFalse(decision.allowsAutomaticSuggestions)
        XCTAssertEqual(decision.profile.status, .partial)
    }

    func testFirefoxUsesMirrorWindowMode() {
        let decision = CompatibilityCatalog().decision(bundleID: "org.mozilla.firefox", domain: nil)

        XCTAssertTrue(decision.enabled)
        XCTAssertEqual(decision.mode, .mirrorWindow)
        XCTAssertEqual(decision.profile.status, .mirrorOnly)
    }

    func testUnknownAppsUseInlineModeWhenPossible() {
        let decision = CompatibilityCatalog().decision(bundleID: "com.example.UnknownEditor", domain: nil)

        XCTAssertTrue(decision.enabled)
        XCTAssertEqual(decision.mode, .inline)
        XCTAssertEqual(decision.overrideMode, .automatic)
        XCTAssertTrue(decision.allowsAutomaticSuggestions)
        XCTAssertEqual(decision.profile.status, .partial)
    }

    func testModeOverridesControlAutomaticManualOnlyAndDisabledDecisions() {
        let catalog = CompatibilityCatalog()

        let automatic = catalog.decision(
            bundleID: "com.microsoft.VSCode",
            domain: nil,
            userModeOverrides: ["com.microsoft.VSCode": .automatic]
        )
        XCTAssertTrue(automatic.enabled)
        XCTAssertEqual(automatic.mode, .inline)
        XCTAssertEqual(automatic.overrideMode, .automatic)
        XCTAssertTrue(automatic.allowsAutomaticSuggestions)

        let manualOnly = catalog.decision(
            bundleID: "com.apple.TextEdit",
            domain: nil,
            userModeOverrides: ["com.apple.TextEdit": .manualOnly]
        )
        XCTAssertTrue(manualOnly.enabled)
        XCTAssertEqual(manualOnly.mode, .inline)
        XCTAssertEqual(manualOnly.overrideMode, .manualOnly)
        XCTAssertFalse(manualOnly.allowsAutomaticSuggestions)

        let disabled = catalog.decision(
            bundleID: "com.apple.TextEdit",
            domain: nil,
            userModeOverrides: ["com.apple.TextEdit": .disabled]
        )
        XCTAssertFalse(disabled.enabled)
        XCTAssertEqual(disabled.mode, .disabled)
        XCTAssertEqual(disabled.overrideMode, .disabled)
    }

    func testDomainOverridesControlActivationAndTakePrecedenceOverAppOverrides() {
        let catalog = CompatibilityCatalog()
        let docsKey = CompatibilityCatalog.overrideKey(forDomain: "docs.google.com")

        let decision = catalog.decision(
            bundleID: "com.google.Chrome",
            domain: "https://docs.google.com/document/d/example",
            userModeOverrides: [
                "com.google.Chrome": .disabled,
                docsKey: .manualOnly
            ]
        )

        XCTAssertTrue(decision.enabled)
        XCTAssertEqual(decision.overrideMode, .manualOnly)
        XCTAssertFalse(decision.allowsAutomaticSuggestions)
        XCTAssertEqual(decision.profile.status, .setupNeeded)
        XCTAssertEqual(decision.ruleSource, .domainRule)
    }

    func testCompatibilityRuleSourceDistinguishesDefaultAppAndUnknownDomain() {
        let catalog = CompatibilityCatalog()
        let defaultDecision = catalog.decision(bundleID: "com.google.Chrome", domain: nil)
        let appRuleDecision = catalog.decision(
            bundleID: "com.google.Chrome",
            domain: nil,
            userModeOverrides: ["com.google.Chrome": .manualOnly]
        )
        let unknownDomainDecision = catalog.decision(
            bundleID: "com.google.Chrome",
            domain: nil,
            userModeOverrides: [
                CompatibilityCatalog.overrideKey(forDomain: "docs.google.com"): .disabled
            ]
        )

        XCTAssertEqual(defaultDecision.ruleSource, .default)
        XCTAssertEqual(appRuleDecision.ruleSource, .appRule)
        XCTAssertTrue(unknownDomainDecision.enabled)
        XCTAssertEqual(unknownDomainDecision.overrideMode, .automatic)
        XCTAssertEqual(unknownDomainDecision.ruleSource, .default)
    }

    func testCompatibilityProfileCodablePreservesLegacyEnabledAndActivationMode() throws {
        let legacyJSON = Data("""
        {
          "bundleID": "com.example.Legacy",
          "displayName": "Legacy",
          "status": "partial",
          "defaultMode": "inline",
          "enabledByDefault": false
        }
        """.utf8)

        let legacyProfile = try JSONDecoder().decode(AppCompatibilityProfile.self, from: legacyJSON)
        XCTAssertEqual(legacyProfile.defaultActivationMode, .disabled)

        let profile = AppCompatibilityProfile(
            bundleID: "com.example.Chat",
            displayName: "Chat",
            status: .partial,
            defaultMode: .inline,
            defaultActivationMode: .manualOnly
        )
        let data = try JSONEncoder().encode(profile)
        let decoded = try JSONDecoder().decode(AppCompatibilityProfile.self, from: data)

        XCTAssertEqual(decoded.defaultActivationMode, .manualOnly)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("enabledByDefault"))
    }

    func testLegacyEnabledOverridesStillControlDecision() {
        let decision = CompatibilityCatalog().decision(
            bundleID: "com.apple.TextEdit",
            domain: nil,
            userEnabledOverrides: ["com.apple.TextEdit": false]
        )

        XCTAssertFalse(decision.enabled)
        XCTAssertEqual(decision.mode, .disabled)
        XCTAssertEqual(decision.overrideMode, .disabled)
    }

    func testGoogleDocsRequiresSetupButSheetsAreUnsupported() {
        let catalog = CompatibilityCatalog()

        let docs = catalog.decision(
            bundleID: "com.google.Chrome",
            domain: "https://docs.google.com/document/d/example"
        )
        XCTAssertEqual(docs.profile.status, .setupNeeded)
        XCTAssertEqual(docs.mode, .inline)
        XCTAssertTrue(docs.enabled)
        XCTAssertEqual(docs.overrideMode, .automatic)
        XCTAssertTrue(docs.allowsAutomaticSuggestions)
        XCTAssertNotNil(docs.setupMessage)

        let sheets = catalog.decision(bundleID: "com.google.Chrome", domain: "docs.google.com/spreadsheets")
        XCTAssertEqual(sheets.profile.status, .unsupported)
        XCTAssertEqual(sheets.mode, .disabled)
        XCTAssertFalse(sheets.enabled)
        XCTAssertFalse(sheets.allowsAutomaticSuggestions)

        let slides = catalog.decision(
            bundleID: "com.google.Chrome",
            domain: "https://docs.google.com/presentation/d/example"
        )
        XCTAssertEqual(slides.profile.status, .unsupported)
        XCTAssertEqual(slides.mode, .disabled)
        XCTAssertFalse(slides.enabled)
        XCTAssertFalse(slides.allowsAutomaticSuggestions)
    }
}
