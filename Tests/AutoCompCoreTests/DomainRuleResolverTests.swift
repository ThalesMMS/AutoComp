import AutoCompCore
import XCTest

final class DomainRuleResolverTests: XCTestCase {
    func testProductionDefaultsPreserveLegacyDomainGates() {
        let resolver = DomainRuleResolver()

        let expectedActions: [(domain: String, action: DomainWebAppRuleAction)] = [
            ("mail.google.com", .deny),
            ("outlook.office.com", .deny),
            ("outlook.live.com", .deny),
            ("docs.google.com", .visualContextRequired),
            ("sheets.google.com", .manualOnly),
            ("slides.google.com", .manualOnly),
            ("example.com", .allow)
        ]

        for expected in expectedActions {
            let resolution = resolver.resolve(
                input: DomainRuleResolver.Input(
                    appBundleID: "com.google.Chrome",
                    activeDomain: expected.domain
                ),
                userRuleset: nil,
                fallbackRuleset: .autocompleteProductionDefaults
            )

            XCTAssertEqual(resolution.effectiveAction.action, expected.action, expected.domain)
        }
    }

    func testPersistedRulesOverrideProductionDefaults() {
        let overrideRule = DomainWebAppRule(
            id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            pattern: .exactHost("mail.google.com"),
            action: .allow,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )
        let userRuleset = DomainWebAppRuleset(rules: [overrideRule])

        let resolution = DomainRuleResolver().resolve(
            input: DomainRuleResolver.Input(
                appBundleID: "com.google.Chrome",
                activeDomain: "mail.google.com"
            ),
            userRuleset: userRuleset,
            fallbackRuleset: .autocompleteProductionDefaults
        )

        XCTAssertEqual(resolution.effectiveAction.action, .allow)
        XCTAssertEqual(resolution.matchedRule, overrideRule)
    }

    func testRulePresetsDoNotContradictProductionDefaults() throws {
        XCTAssertEqual(
            try XCTUnwrap(DomainWebAppRulePresetCatalog.preset(id: DomainWebAppRulePresetCatalog.PresetId.googleDocs)).defaultAction,
            .visualContextRequired
        )
        XCTAssertEqual(
            try XCTUnwrap(DomainWebAppRulePresetCatalog.preset(id: DomainWebAppRulePresetCatalog.PresetId.googleSheets)).defaultAction,
            .manualOnly
        )
        XCTAssertEqual(
            try XCTUnwrap(DomainWebAppRulePresetCatalog.preset(id: DomainWebAppRulePresetCatalog.PresetId.googleSlides)).defaultAction,
            .manualOnly
        )
        XCTAssertEqual(
            try XCTUnwrap(DomainWebAppRulePresetCatalog.preset(id: DomainWebAppRulePresetCatalog.PresetId.emailWebApps)).defaultAction,
            .deny
        )
    }
}
