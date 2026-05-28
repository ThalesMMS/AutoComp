import Foundation

public enum RiskyHostAppCategory: String, Codable, CaseIterable, Sendable {
    case terminal
    case chat
    case codeEditor
}

public struct RiskyHostAppPolicy: Sendable {
    public static let terminalBundleIDs: Set<String> = [
        "com.apple.Terminal",
        "com.googlecode.iterm2",
        "com.github.wez.wezterm",
        "org.alacritty",
        "com.mitchellh.ghostty",
        "dev.warp.Warp-Stable"
    ]

    public static let chatBundleIDs: Set<String> = [
        "com.apple.MobileSMS",
        "com.microsoft.teams2",
        "net.whatsapp.WhatsApp",
        "com.tinyspeck.slackmacgap",
        "com.hnc.Discord",
        "com.hnc.DiscordPTB",
        "com.hnc.DiscordCanary",
        "ru.keepcoder.Telegram",
        "com.tdesktop.Telegram"
    ]

    public static let codeEditorBundleIDs: Set<String> = [
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
    ]

    public static let chatDomains: Set<String> = [
        "chat.openai.com",
        "chatgpt.com",
        "claude.ai",
        "gemini.google.com",
        "teams.microsoft.com",
        "discord.com",
        "slack.com",
        "web.whatsapp.com",
        "web.telegram.org"
    ]

    public static func category(bundleID: String, domain: String?) -> RiskyHostAppCategory? {
        if terminalBundleIDs.contains(bundleID) {
            return .terminal
        }
        if chatBundleIDs.contains(bundleID) || isChatDomain(domain) {
            return .chat
        }
        if codeEditorBundleIDs.contains(bundleID) {
            return .codeEditor
        }
        return nil
    }

    public static func isTerminal(bundleID: String) -> Bool {
        terminalBundleIDs.contains(bundleID)
    }

    public static func isChat(bundleID: String, domain: String?) -> Bool {
        category(bundleID: bundleID, domain: domain) == .chat
    }

    public static func containsReturn(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0 == "\n" || $0 == "\r" }
    }

    public static func isClearlyEditableTarget(_ context: TextContext) -> Bool {
        guard !context.captureSources.contains(.keystrokeBufferLowTrust) else {
            return false
        }

        if let selectedRange = context.selectedRange,
           selectedRange.location != NSNotFound,
           selectedRange.location >= 0,
           selectedRange.length >= 0 {
            return true
        }

        if let role = context.stableFieldIdentity?.role?.lowercased(),
           role.contains("text") || role.contains("edit") || role.contains("combo") {
            return true
        }

        if let subrole = context.stableFieldIdentity?.subrole?.lowercased(),
           subrole.contains("text") || subrole.contains("edit") || subrole.contains("combo") {
            return true
        }

        switch context.caretGeometryQuality {
        case .directCaret, .glyph, .lineMetric, .screenOCR:
            return context.caretRect != nil || context.previousGlyphRect != nil || context.nextGlyphRect != nil
        case .elementFrame, .unavailable:
            return false
        }
    }

    private static func isChatDomain(_ domain: String?) -> Bool {
        guard let domain else {
            return false
        }

        let normalized = normalizedDomain(domain)
        return chatDomains.contains { chatDomain in
            normalized == chatDomain || normalized.hasSuffix(".\(chatDomain)") || normalized.hasPrefix("\(chatDomain)/")
        }
    }

    private static func normalizedDomain(_ domain: String) -> String {
        var normalized = domain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if normalized.hasPrefix("https://") {
            normalized.removeFirst("https://".count)
        } else if normalized.hasPrefix("http://") {
            normalized.removeFirst("http://".count)
        }

        if let fragmentIndex = normalized.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            normalized = String(normalized[..<fragmentIndex])
        }

        return normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }
}
