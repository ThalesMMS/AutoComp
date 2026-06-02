import Foundation

public struct WritingRule: Codable, Equatable, Hashable, Sendable {
    public var text: String

    public init(_ text: String) {
        self.text = WritingPreferences.normalizedRule(text)
    }
}

public enum WritingRulesCatalog {
    public static let suggestedRules: [WritingRule] = [
        WritingRule("Escreva de forma objetiva"),
        WritingRule("Use português do Brasil"),
        WritingRule("Tom profissional"),
        WritingRule("Frases curtas"),
        WritingRule("Evite emoji"),
        WritingRule("Não use travessão"),
        WritingRule("Não invente informações")
    ]
}

public struct LanguageHint: Codable, Equatable, Hashable, Sendable {
    public var name: String

    public init(_ name: String) {
        self.name = WritingPreferences.normalizedLanguageHint(name)
    }
}

public enum LanguageHintCatalog {
    public static let suggestedHints: [LanguageHint] = [
        LanguageHint("Portuguese (Brazil)"),
        LanguageHint("English"),
        LanguageHint("Spanish"),
        LanguageHint("French"),
        LanguageHint("German"),
        LanguageHint("Italian")
    ]
}

public struct WritingPreferences: Codable, Equatable, Sendable {
    public static let maxRules = 10
    public static let maxRuleCharacters = 60
    public static let maxLanguageHints = 6
    public static let maxLanguageHintCharacters = 40

    public static let suggestedRules = WritingRulesCatalog.suggestedRules.map(\.text)
    public static let suggestedLanguageHints = LanguageHintCatalog.suggestedHints.map(\.name)

    public var enabled: Bool
    public var rules: [String]
    public var languageHints: [String]

    public init(
        enabled: Bool = false,
        rules: [String] = [],
        languageHints: [String] = []
    ) {
        self.enabled = enabled
        self.rules = Self.normalizedRules(rules)
        self.languageHints = Self.normalizedLanguageHints(languageHints)
    }

    public var promptPreview: String? {
        guard enabled,
              (!rules.isEmpty || !languageHints.isEmpty) else {
            return nil
        }

        var sections: [String] = []
        if !rules.isEmpty {
            sections.append(
                rules
                    .map { "- \($0)" }
                    .joined(separator: "\n")
            )
        }
        if !languageHints.isEmpty {
            sections.append(
                "Language hints: follow the surrounding text language first. If ambiguous, prefer: \(languageHints.joined(separator: ", "))."
            )
        }

        return """
        Writing preferences:
        \(sections.joined(separator: "\n"))
        """
    }

    public func adding(_ rule: String) -> WritingPreferences {
        WritingPreferences(enabled: enabled, rules: rules + [rule], languageHints: languageHints)
    }

    public func removing(_ rule: String) -> WritingPreferences {
        let key = Self.normalizedRule(rule).lowercased()
        return WritingPreferences(
            enabled: enabled,
            rules: rules.filter { Self.normalizedRule($0).lowercased() != key },
            languageHints: languageHints
        )
    }

    public func addingLanguageHint(_ hint: String) -> WritingPreferences {
        WritingPreferences(enabled: enabled, rules: rules, languageHints: languageHints + [hint])
    }

    public func removingLanguageHint(_ hint: String) -> WritingPreferences {
        let key = Self.normalizedLanguageHint(hint).lowercased()
        return WritingPreferences(
            enabled: enabled,
            rules: rules,
            languageHints: languageHints.filter { Self.normalizedLanguageHint($0).lowercased() != key }
        )
    }

    public static func normalizedRules(_ rawRules: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for rawRule in rawRules {
            let rule = normalizedRule(rawRule)
            guard !rule.isEmpty else {
                continue
            }

            let key = rule.lowercased()
            guard seen.insert(key).inserted else {
                continue
            }

            result.append(rule)
            if result.count == maxRules {
                break
            }
        }

        return result
    }

    public static func normalizedRule(_ rawRule: String) -> String {
        let collapsed = rawRule
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard collapsed.count > maxRuleCharacters else {
            return collapsed
        }

        return String(collapsed.prefix(maxRuleCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func normalizedLanguageHints(_ rawHints: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []

        for rawHint in rawHints {
            let hint = normalizedLanguageHint(rawHint)
            guard !hint.isEmpty else {
                continue
            }

            let key = hint.lowercased()
            guard seen.insert(key).inserted else {
                continue
            }

            result.append(hint)
            if result.count == maxLanguageHints {
                break
            }
        }

        return result
    }

    public static func normalizedLanguageHint(_ rawHint: String) -> String {
        let collapsed = rawHint
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard collapsed.count > maxLanguageHintCharacters else {
            return collapsed
        }

        return String(collapsed.prefix(maxLanguageHintCharacters))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case rules
        case languageHints
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            enabled: try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false,
            rules: try container.decodeIfPresent([String].self, forKey: .rules) ?? [],
            languageHints: try container.decodeIfPresent([String].self, forKey: .languageHints) ?? []
        )
    }
}
