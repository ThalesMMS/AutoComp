import AppKit
import AutoCompCore
import Foundation

enum EmojiSkinTone: String, CaseIterable, Codable, Identifiable, Sendable {
    case system
    case light
    case mediumLight
    case medium
    case mediumDark
    case dark

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .system:
            return "Default"
        case .light:
            return "Light"
        case .mediumLight:
            return "Medium light"
        case .medium:
            return "Medium"
        case .mediumDark:
            return "Medium dark"
        case .dark:
            return "Dark"
        }
    }
}

enum EmojiGenderPresentation: String, CaseIterable, Codable, Identifiable, Sendable {
    case neutral
    case feminine
    case masculine

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .neutral:
            return "Neutral"
        case .feminine:
            return "Feminine"
        case .masculine:
            return "Masculine"
        }
    }
}

struct EmojiVariantPreferences: Codable, Equatable, Sendable {
    var isEnabled: Bool
    var skinTone: EmojiSkinTone
    var genderPresentation: EmojiGenderPresentation

    init(
        isEnabled: Bool = true,
        skinTone: EmojiSkinTone = .system,
        genderPresentation: EmojiGenderPresentation = .neutral
    ) {
        self.isEnabled = isEnabled
        self.skinTone = skinTone
        self.genderPresentation = genderPresentation
    }

    func glyph(for entry: EmojiCatalogEntry) -> String {
        if genderPresentation != .neutral,
           let genderGlyph = entry.genderVariants[genderPresentation] {
            return genderGlyph
        }

        if skinTone != .system,
           let toneGlyph = entry.skinToneVariants[skinTone] {
            return toneGlyph
        }

        return entry.glyph
    }
}

final class EmojiVariantPreferencesStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "emojiVariantPreferences") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> EmojiVariantPreferences {
        guard let data = defaults.data(forKey: key),
              let preferences = try? JSONDecoder().decode(EmojiVariantPreferences.self, from: data) else {
            return EmojiVariantPreferences()
        }

        return preferences
    }

    func save(_ preferences: EmojiVariantPreferences) throws {
        let data = try JSONEncoder().encode(preferences)
        defaults.set(data, forKey: key)
    }
}

struct EmojiCatalogEntry: Identifiable, Equatable, Sendable {
    var aliases: [String]
    var glyph: String
    var keywords: [String]
    var skinToneVariants: [EmojiSkinTone: String]
    var genderVariants: [EmojiGenderPresentation: String]

    init(
        aliases: [String],
        glyph: String,
        keywords: [String] = [],
        skinToneVariants: [EmojiSkinTone: String] = [:],
        genderVariants: [EmojiGenderPresentation: String] = [:]
    ) {
        self.aliases = aliases.map(Self.normalized)
        self.glyph = glyph
        self.keywords = keywords.map(Self.normalized)
        self.skinToneVariants = skinToneVariants
        self.genderVariants = genderVariants
    }

    var id: String {
        primaryAlias
    }

    var primaryAlias: String {
        aliases.first ?? ""
    }

    private static func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
    }
}

enum EmojiCatalog {
    static let defaultEntries: [EmojiCatalogEntry] = [
        EmojiCatalogEntry(aliases: ["smile", "smiley"], glyph: "😄", keywords: ["happy", "joy", "grin"]),
        EmojiCatalogEntry(aliases: ["laugh", "lol"], glyph: "😂", keywords: ["tears", "funny"]),
        EmojiCatalogEntry(aliases: ["heart", "love"], glyph: "❤️", keywords: ["red", "like"]),
        EmojiCatalogEntry(
            aliases: ["thumbsup", "+1"],
            glyph: "👍",
            keywords: ["approve", "yes", "ok"],
            skinToneVariants: [
                .light: "👍🏻",
                .mediumLight: "👍🏼",
                .medium: "👍🏽",
                .mediumDark: "👍🏾",
                .dark: "👍🏿"
            ]
        ),
        EmojiCatalogEntry(
            aliases: ["wave"],
            glyph: "👋",
            keywords: ["hello", "hi"],
            skinToneVariants: [
                .light: "👋🏻",
                .mediumLight: "👋🏼",
                .medium: "👋🏽",
                .mediumDark: "👋🏾",
                .dark: "👋🏿"
            ]
        ),
        EmojiCatalogEntry(
            aliases: ["shrug"],
            glyph: "🤷",
            keywords: ["unknown", "whatever"],
            genderVariants: [
                .feminine: "🤷‍♀️",
                .masculine: "🤷‍♂️"
            ]
        ),
        EmojiCatalogEntry(aliases: ["fire"], glyph: "🔥", keywords: ["hot", "lit"]),
        EmojiCatalogEntry(aliases: ["rocket"], glyph: "🚀", keywords: ["ship", "launch"]),
        EmojiCatalogEntry(aliases: ["check", "done"], glyph: "✅", keywords: ["yes", "complete"]),
        EmojiCatalogEntry(aliases: ["x", "cross"], glyph: "❌", keywords: ["no", "remove"]),
        EmojiCatalogEntry(aliases: ["sob", "cry"], glyph: "😭", keywords: ["sad", "tears"]),
        EmojiCatalogEntry(aliases: ["pray", "thanks"], glyph: "🙏", keywords: ["please", "hope"]),
        EmojiCatalogEntry(aliases: ["clap"], glyph: "👏", keywords: ["applause", "bravo"]),
        EmojiCatalogEntry(aliases: ["ok_hand"], glyph: "👌", keywords: ["ok", "perfect"]),
        EmojiCatalogEntry(aliases: ["thinking"], glyph: "🤔", keywords: ["hmm", "question"]),
        EmojiCatalogEntry(aliases: ["eyes"], glyph: "👀", keywords: ["look", "watch"]),
        EmojiCatalogEntry(aliases: ["party", "tada"], glyph: "🎉", keywords: ["celebrate", "confetti"]),
        EmojiCatalogEntry(aliases: ["star"], glyph: "⭐️", keywords: ["favorite", "rating"]),
        EmojiCatalogEntry(aliases: ["sparkles"], glyph: "✨", keywords: ["magic", "clean"])
    ]
}

struct EmojiMatch: Identifiable, Equatable, Sendable {
    var entry: EmojiCatalogEntry
    var score: Int

    var id: String {
        entry.id
    }
}

struct EmojiMatcher: Sendable {
    var entries: [EmojiCatalogEntry] = EmojiCatalog.defaultEntries

    func matches(for rawQuery: String, limit: Int = 6) -> [EmojiMatch] {
        let query = normalized(rawQuery)
        guard !query.isEmpty else {
            return []
        }

        return entries.compactMap { entry in
            score(entry: entry, query: query).map { EmojiMatch(entry: entry, score: $0) }
        }
        .sorted { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.entry.primaryAlias < rhs.entry.primaryAlias
            }
            return lhs.score < rhs.score
        }
        .prefix(limit)
        .map { $0 }
    }

    func exactMatch(for rawQuery: String) -> EmojiMatch? {
        let query = normalized(rawQuery)
        return entries.first { $0.aliases.contains(query) }
            .map { EmojiMatch(entry: $0, score: 0) }
    }

    private func score(entry: EmojiCatalogEntry, query: String) -> Int? {
        if entry.aliases.contains(query) {
            return 0
        }

        if let alias = entry.aliases.first(where: { $0.hasPrefix(query) }) {
            return 10 + alias.count - query.count
        }

        if let keyword = entry.keywords.first(where: { $0.hasPrefix(query) }) {
            return 30 + keyword.count - query.count
        }

        if let alias = entry.aliases.first(where: { $0.contains(query) }) {
            return 50 + alias.count - query.count
        }

        if let keyword = entry.keywords.first(where: { $0.contains(query) }) {
            return 70 + keyword.count - query.count
        }

        return nil
    }

    private func normalized(_ value: String) -> String {
        value
            .trimmingCharacters(in: CharacterSet(charactersIn: ":").union(.whitespacesAndNewlines))
            .lowercased()
            .replacingOccurrences(of: " ", with: "_")
    }
}

struct EmojiQueryRun: Equatable, Sendable {
    var query: String
    var hasClosingColon: Bool
    var replacementUTF16Length: Int
    var stableFieldIdentity: StableFieldIdentity?
}

struct EmojiTriggerStateMachine: Equatable, Sendable {
    private(set) var activeRun: EmojiQueryRun?

    mutating func update(
        textBeforeCursor: String,
        stableFieldIdentity: StableFieldIdentity? = nil
    ) -> EmojiQueryRun? {
        let run = Self.queryRun(in: textBeforeCursor, stableFieldIdentity: stableFieldIdentity)
        activeRun = run
        return run
    }

    mutating func cancel() {
        activeRun = nil
    }

    static func queryRun(
        in textBeforeCursor: String,
        stableFieldIdentity: StableFieldIdentity? = nil
    ) -> EmojiQueryRun? {
        let pattern = #"(^|\s):([A-Za-z0-9_+\-]{1,32})(:?)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }

        let range = NSRange(textBeforeCursor.startIndex..<textBeforeCursor.endIndex, in: textBeforeCursor)
        guard let match = expression.firstMatch(in: textBeforeCursor, range: range),
              let queryRange = Range(match.range(at: 2), in: textBeforeCursor),
              let closingRange = Range(match.range(at: 3), in: textBeforeCursor) else {
            return nil
        }

        let boundaryLength = match.range(at: 1).length
        let triggerStart = match.range(at: 0).location + boundaryLength
        return EmojiQueryRun(
            query: String(textBeforeCursor[queryRange]).lowercased(),
            hasClosingColon: !textBeforeCursor[closingRange].isEmpty,
            replacementUTF16Length: textBeforeCursor.utf16.count - triggerStart,
            stableFieldIdentity: stableFieldIdentity
        )
    }
}

enum EmojiKeyboardCommand: Equatable, Sendable {
    case acceptSelected
    case cancel
    case selectPrevious
    case selectNext
}
