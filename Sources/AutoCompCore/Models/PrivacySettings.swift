import Foundation

public enum PrivacyCollectionRuleSource: String, Codable, Equatable, Sendable {
    case collectionDisabled = "collection-disabled"
    case domainRule = "domain-rule"
    case appRule = "app-rule"
    case defaultAllow = "default-allow"
}

public struct PrivacyCollectionDecision: Equatable, Sendable {
    public let allowed: Bool
    public let ruleSource: PrivacyCollectionRuleSource

    public init(allowed: Bool, ruleSource: PrivacyCollectionRuleSource) {
        self.allowed = allowed
        self.ruleSource = ruleSource
    }
}

public struct PrivacySettings: Codable, Equatable, Sendable {
    public var collectionEnabled: Bool
    public var clipboardContextEnabled: Bool
    public var screenContextEnabled: Bool
    public var productivityMetricsEnabled: Bool
    public var localPersonalizationEnabled: Bool
    public var personalizationStrength: Double
    public var writingPreferences: WritingPreferences
    public var perAppRules: [String: Bool]
    public var perDomainRules: [String: Bool]

    // v2+ domain/web-app rule builder settings
    public var domainWebAppRules: DomainWebAppRules

    public init(
        collectionEnabled: Bool = false,
        clipboardContextEnabled: Bool = false,
        screenContextEnabled: Bool = false,
        productivityMetricsEnabled: Bool = true,
        localPersonalizationEnabled: Bool = false,
        personalizationStrength: Double = 0.35,
        writingPreferences: WritingPreferences = WritingPreferences(),
        perAppRules: [String: Bool] = [:],
        perDomainRules: [String: Bool] = [:],
        domainWebAppRules: DomainWebAppRules = DomainWebAppRules()
    ) {
        self.collectionEnabled = collectionEnabled
        self.clipboardContextEnabled = clipboardContextEnabled
        self.screenContextEnabled = screenContextEnabled
        self.productivityMetricsEnabled = productivityMetricsEnabled
        self.localPersonalizationEnabled = localPersonalizationEnabled
        self.personalizationStrength = personalizationStrength
        self.writingPreferences = writingPreferences
        self.perAppRules = perAppRules
        self.perDomainRules = perDomainRules
        self.domainWebAppRules = domainWebAppRules
    }

    private enum CodingKeys: String, CodingKey {
        case collectionEnabled
        case clipboardContextEnabled
        case screenContextEnabled
        case productivityMetricsEnabled
        case localPersonalizationEnabled
        case personalizationStrength
        case writingPreferences
        case perAppRules
        case perDomainRules
        case domainWebAppRules
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            collectionEnabled: try container.decodeIfPresent(Bool.self, forKey: .collectionEnabled) ?? false,
            clipboardContextEnabled: try container.decodeIfPresent(Bool.self, forKey: .clipboardContextEnabled) ?? false,
            screenContextEnabled: try container.decodeIfPresent(Bool.self, forKey: .screenContextEnabled) ?? false,
            productivityMetricsEnabled: try container.decodeIfPresent(Bool.self, forKey: .productivityMetricsEnabled) ?? true,
            localPersonalizationEnabled: try container.decodeIfPresent(Bool.self, forKey: .localPersonalizationEnabled) ?? false,
            personalizationStrength: try container.decodeIfPresent(Double.self, forKey: .personalizationStrength) ?? 0.35,
            writingPreferences: try container.decodeIfPresent(WritingPreferences.self, forKey: .writingPreferences) ?? WritingPreferences(),
            perAppRules: try container.decodeIfPresent([String: Bool].self, forKey: .perAppRules) ?? [:],
            perDomainRules: try container.decodeIfPresent([String: Bool].self, forKey: .perDomainRules) ?? [:],
            domainWebAppRules: try container.decodeIfPresent(DomainWebAppRules.self, forKey: .domainWebAppRules) ?? DomainWebAppRules()
        )
    }

    public var personalizationPromptSampleLimit: Int {
        guard localPersonalizationEnabled else {
            return 0
        }

        let normalizedStrength = min(max(personalizationStrength, 0), 1)
        guard normalizedStrength > 0 else {
            return 0
        }

        let maxSamples = PersonalizationSampleRecorder.defaultPromptSampleLimit
        return min(maxSamples, max(1, Int(ceil(normalizedStrength * Double(maxSamples)))))
    }

    public func allowsCollection(appBundleID: String, domain: String?) -> Bool {
        collectionDecision(appBundleID: appBundleID, domain: domain).allowed
    }

    public func collectionDecision(appBundleID: String, domain: String?) -> PrivacyCollectionDecision {
        guard collectionEnabled else {
            return PrivacyCollectionDecision(allowed: false, ruleSource: .collectionDisabled)
        }

        if let domainRule = collectionRule(forDomain: domain) {
            return PrivacyCollectionDecision(allowed: domainRule, ruleSource: .domainRule)
        }

        if let appRule = perAppRules[appBundleID] {
            return PrivacyCollectionDecision(allowed: appRule, ruleSource: .appRule)
        }

        return PrivacyCollectionDecision(allowed: true, ruleSource: .defaultAllow)
    }

    public func collectionRule(forDomain domain: String?) -> Bool? {
        guard let domain else {
            return nil
        }

        for candidate in DomainNormalization.specificityCandidates(for: domain) {
            if let directRule = perDomainRules[candidate] {
                return directRule
            }

            for (storedDomain, rule) in perDomainRules
                where DomainNormalization.canonicalDomainString(from: storedDomain) == candidate {
                return rule
            }
        }

        return nil
    }

}
