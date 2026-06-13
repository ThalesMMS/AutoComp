import Foundation

/// A single entry point for resolving the effective domain/web-app rule for a given focused context.
///
/// This resolver is intentionally host-oriented to avoid handling (or logging) full URLs.
public struct DomainRuleResolver: Sendable {

    public struct Input: Sendable, Equatable {
        public var appBundleID: String
        public var activeDomain: String?

        public init(appBundleID: String, activeDomain: String?) {
            self.appBundleID = appBundleID
            self.activeDomain = activeDomain
        }
    }

    public enum EffectiveAction: Sendable, Equatable {
        case allow
        case deny(reasonKey: String)
        case manualOnly(reasonKey: String)
        case visualContextRequired(reasonKey: String)

        public var reasonKey: String? {
            switch self {
            case .allow:
                return nil
            case .deny(let key), .manualOnly(let key), .visualContextRequired(let key):
                return key
            }
        }

        public var action: DomainWebAppRuleAction {
            switch self {
            case .allow:
                return .allow
            case .deny:
                return .deny
            case .manualOnly:
                return .manualOnly
            case .visualContextRequired:
                return .visualContextRequired
            }
        }
    }

    public struct Resolution: Sendable, Equatable {
        public var input: Input
        public var matchedRule: DomainWebAppRule?
        public var effectiveAction: EffectiveAction

        public init(input: Input, matchedRule: DomainWebAppRule?, effectiveAction: EffectiveAction) {
            self.input = input
            self.matchedRule = matchedRule
            self.effectiveAction = effectiveAction
        }
    }

    public init() {}

    /// Resolves the rule given a host string and a set of rules.
    ///
    /// - Important: `input.activeDomain` must be host-only (or host + coarse path segment) and must not
    ///   include query strings, fragments, or document identifiers.
    public func resolve(input: Input, ruleset: DomainWebAppRuleset?) -> Resolution {
        if let matched = matchingRule(input: input, ruleset: ruleset) {
            return Resolution(
                input: input,
                matchedRule: matched,
                effectiveAction: mapActionToEffectiveAction(matched.action)
            )
        }

        return Resolution(input: input, matchedRule: nil, effectiveAction: .allow)
    }

    /// Resolves persisted user rules first, then falls back to production defaults.
    ///
    /// Keeping the two rule sets separate is intentional: a user-created broad allow rule should be
    /// able to override built-in deny/manual defaults without losing to a more-specific fallback rule.
    public func resolve(
        input: Input,
        userRuleset: DomainWebAppRuleset?,
        fallbackRuleset: DomainWebAppRuleset?
    ) -> Resolution {
        if let matched = matchingRule(input: input, ruleset: userRuleset) {
            return Resolution(
                input: input,
                matchedRule: matched,
                effectiveAction: mapActionToEffectiveAction(matched.action)
            )
        }

        return resolve(input: input, ruleset: fallbackRuleset)
    }

    private func matchingRule(input: Input, ruleset: DomainWebAppRuleset?) -> DomainWebAppRule? {
        guard let host = input.activeDomain, let ruleset else {
            return nil
        }
        return DomainPatternMatcher.bestMatchingRule(forHost: host, rules: ruleset.rules)
    }

    private func mapActionToEffectiveAction(_ action: DomainWebAppRuleAction) -> EffectiveAction {
        switch action {
        case .allow:
            return .allow
        case .deny:
            return .deny(reasonKey: "domain-denied")
        case .manualOnly:
            return .manualOnly(reasonKey: "domain-manual-only")
        case .visualContextRequired:
            return .visualContextRequired(reasonKey: "domain-needs-visual-context")
        }
    }
}
