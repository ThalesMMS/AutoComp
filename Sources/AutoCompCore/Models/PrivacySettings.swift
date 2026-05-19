import Foundation

public struct PrivacySettings: Codable, Equatable, Sendable {
    public var collectionEnabled: Bool
    public var clipboardContextEnabled: Bool
    public var screenContextEnabled: Bool
    public var personalizationStrength: Double
    public var perAppRules: [String: Bool]
    public var perDomainRules: [String: Bool]

    public init(
        collectionEnabled: Bool = false,
        clipboardContextEnabled: Bool = false,
        screenContextEnabled: Bool = false,
        personalizationStrength: Double = 0.35,
        perAppRules: [String: Bool] = [:],
        perDomainRules: [String: Bool] = [:]
    ) {
        self.collectionEnabled = collectionEnabled
        self.clipboardContextEnabled = clipboardContextEnabled
        self.screenContextEnabled = screenContextEnabled
        self.personalizationStrength = personalizationStrength
        self.perAppRules = perAppRules
        self.perDomainRules = perDomainRules
    }

    public func allowsCollection(appBundleID: String, domain: String?) -> Bool {
        guard collectionEnabled else {
            return false
        }

        if let domain, let domainRule = perDomainRules[domain] {
            return domainRule
        }

        if let appRule = perAppRules[appBundleID] {
            return appRule
        }

        return true
    }
}
