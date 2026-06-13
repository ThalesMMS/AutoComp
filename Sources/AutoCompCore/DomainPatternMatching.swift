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

public struct GoogleDocsContext: Sendable, Equatable {
    public enum AppGate: Sendable, Equatable {
        case any
        case chrome
        case browser
        case webLike
    }

    public enum Surface: String, Sendable, Hashable {
        case document
        case spreadsheet
        case presentation
        case other
    }

    public let bundleID: String
    public let normalizedDomain: String
    public let surface: Surface

    public init(bundleID: String, normalizedDomain: String, surface: Surface) {
        self.bundleID = bundleID
        self.normalizedDomain = normalizedDomain
        self.surface = surface
    }

    public static func match(
        bundleID: String,
        domain: String?,
        appGate: AppGate = .any,
        allowedSurfaces: Set<Surface> = [.document]
    ) -> GoogleDocsContext? {
        guard passes(appGate, bundleID: bundleID),
              let normalizedDomain = normalizedDomain(from: domain),
              let surface = surface(forNormalizedDomain: normalizedDomain),
              allowedSurfaces.contains(surface) else {
            return nil
        }

        return GoogleDocsContext(
            bundleID: bundleID,
            normalizedDomain: normalizedDomain,
            surface: surface
        )
    }

    public static func matches(
        bundleID: String,
        domain: String?,
        appGate: AppGate = .any,
        allowedSurfaces: Set<Surface> = [.document]
    ) -> Bool {
        match(
            bundleID: bundleID,
            domain: domain,
            appGate: appGate,
            allowedSurfaces: allowedSurfaces
        ) != nil
    }

    public static func surface(for domain: String?) -> Surface? {
        guard let normalizedDomain = normalizedDomain(from: domain) else {
            return nil
        }
        return surface(forNormalizedDomain: normalizedDomain)
    }

    private static func normalizedDomain(from domain: String?) -> String? {
        domain.flatMap(DomainNormalization.canonicalDomainString(from:))
    }

    private static func surface(forNormalizedDomain normalizedDomain: String) -> Surface? {
        let components = normalizedDomain
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard components.first == "docs.google.com" else {
            return nil
        }

        guard components.count > 1 else {
            return .document
        }

        switch components[1] {
        case "document":
            return .document
        case "spreadsheets":
            return .spreadsheet
        case "presentation":
            return .presentation
        default:
            return .other
        }
    }

    private static func passes(_ appGate: AppGate, bundleID: String) -> Bool {
        switch appGate {
        case .any:
            return true
        case .chrome:
            return bundleID == "com.google.Chrome"
        case .browser:
            return WebHostApps.isBrowser(bundleID)
        case .webLike:
            return WebHostApps.isWebLike(bundleID)
        }
    }
}
