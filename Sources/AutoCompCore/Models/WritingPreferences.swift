import Foundation

public struct WritingPreferences: Codable, Equatable, Sendable {
    public static let maxRules = 10
    public static let maxRuleCharacters = 60

    public static let suggestedRules = [
        "Escreva de forma objetiva",
        "Use português do Brasil",
        "Tom profissional",
        "Frases curtas",
        "Evite emoji",
        "Não use travessão",
        "Não invente informações"
    ]

    public var enabled: Bool
    public var rules: [String]

    public init(enabled: Bool = false, rules: [String] = []) {
        self.enabled = enabled
        self.rules = Self.normalizedRules(rules)
    }

    public var promptPreview: String? {
        guard enabled,
              !rules.isEmpty else {
            return nil
        }

        let previewRules = rules
            .map { "- \($0)" }
            .joined(separator: "\n")

        return """
        Writing preferences:
        \(previewRules)
        """
    }

    public func adding(_ rule: String) -> WritingPreferences {
        WritingPreferences(enabled: enabled, rules: rules + [rule])
    }

    public func removing(_ rule: String) -> WritingPreferences {
        let key = Self.normalizedRule(rule).lowercased()
        return WritingPreferences(
            enabled: enabled,
            rules: rules.filter { Self.normalizedRule($0).lowercased() != key }
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
}
