import Foundation

public struct DomainPatternMatch: Sendable, Equatable {
    public enum Specificity: Int, Sendable, Comparable {
        case any = 0
        case subdomainWildcard = 1
        case exact = 2

        public static func < (lhs: Specificity, rhs: Specificity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }
    }

    public var isMatch: Bool
    public var specificity: Specificity

    public init(isMatch: Bool, specificity: Specificity) {
        self.isMatch = isMatch
        self.specificity = specificity
    }
}

public enum DomainPatternMatcher {
    /// Normalizes a host string for matching.
    ///
    /// - Important: This is **host-only** normalization. Do not pass full URLs.
    public static func normalizeHost(_ host: String) -> String? {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        // Strip a trailing dot (rare but valid in DNS; treat as equivalent).
        let lowercased = trimmed.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        guard !lowercased.isEmpty else { return nil }
        return lowercased
    }

    public static func match(pattern: DomainPattern, host rawHost: String) -> DomainPatternMatch {
        guard let host = normalizeHost(rawHost) else {
            return DomainPatternMatch(isMatch: false, specificity: .any)
        }

        switch pattern.kind {
        case .any:
            return DomainPatternMatch(isMatch: true, specificity: .any)

        case .exact:
            let isMatch = host == pattern.value
            return DomainPatternMatch(isMatch: isMatch, specificity: .exact)

        case .subdomainWildcard:
            // Wildcard should match subdomains only, not the base domain.
            // e.g. pattern *.example.com matches a.example.com and b.c.example.com.
            let suffix = "." + pattern.value
            let isMatch = host.hasSuffix(suffix) && host != pattern.value
            return DomainPatternMatch(isMatch: isMatch, specificity: .subdomainWildcard)
        }
    }

    /// Returns the best matching rule using deterministic precedence.
    ///
    /// Precedence:
    /// 1. Enabled rules only.
    /// 2. Higher specificity: exact > subdomain wildcard > any.
    /// 3. For ties on specificity, longer pattern value wins.
    /// 4. Final stable tie-breaker: rule UUID string (ascending).
    public static func bestMatchingRule(forHost host: String, rules: [DomainWebAppRule]) -> DomainWebAppRule? {
        let enabledRules = rules.filter { $0.isEnabled }

        return enabledRules
            .compactMap { rule -> (DomainWebAppRule, DomainPatternMatch, Int) in
                let m = match(pattern: rule.pattern, host: host)
                let length = rule.pattern.value.count
                return (rule, m, length)
            }
            .filter { $0.1.isMatch }
            .sorted { lhs, rhs in
                if lhs.1.specificity != rhs.1.specificity {
                    return lhs.1.specificity > rhs.1.specificity
                }
                if lhs.2 != rhs.2 {
                    return lhs.2 > rhs.2
                }
                return lhs.0.id.uuidString < rhs.0.id.uuidString
            }
            .first?
            .0
    }
}
