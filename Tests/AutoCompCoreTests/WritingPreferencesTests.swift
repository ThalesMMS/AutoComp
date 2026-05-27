import AutoCompCore
import XCTest

final class WritingPreferencesTests: XCTestCase {
    func testNormalizesWhitespaceAndDropsEmptyRules() {
        let preferences = WritingPreferences(
            enabled: true,
            rules: ["  Write   objectively  ", "", "\nUse short sentences\n"]
        )

        XCTAssertEqual(preferences.rules, ["Write objectively", "Use short sentences"])
    }

    func testDeduplicatesCaseInsensitively() {
        let preferences = WritingPreferences(
            enabled: true,
            rules: ["Avoid emoji", "avoid EMOJI", "Use short sentences"]
        )

        XCTAssertEqual(preferences.rules, ["Avoid emoji", "Use short sentences"])
    }

    func testLimitsRuleCountAndLength() {
        let longRule = String(repeating: "a", count: 80)
        let preferences = WritingPreferences(
            enabled: true,
            rules: [longRule] + (0..<12).map { "Rule \($0)" }
        )

        XCTAssertEqual(preferences.rules.count, WritingPreferences.maxRules)
        XCTAssertEqual(preferences.rules.first?.count, WritingPreferences.maxRuleCharacters)
        XCTAssertTrue(preferences.rules.allSatisfy { $0.count <= WritingPreferences.maxRuleCharacters })
    }

    func testAddingRulePreservesLimitsAndDeduplication() {
        let preferences = WritingPreferences(enabled: true, rules: ["Avoid emoji"])
            .adding("avoid emoji")
            .adding("Use short sentences")

        XCTAssertEqual(preferences.rules, ["Avoid emoji", "Use short sentences"])
    }

    func testPromptPreviewOnlyRendersEnabledRules() {
        XCTAssertNil(WritingPreferences(enabled: false, rules: ["Write objectively"]).promptPreview)
        XCTAssertNil(WritingPreferences(enabled: true).promptPreview)

        let preferences = WritingPreferences(
            enabled: true,
            rules: ["Write objectively", "Avoid emoji"]
        )

        XCTAssertEqual(preferences.promptPreview, "Writing preferences:\n- Write objectively\n- Avoid emoji")
    }

    func testSuggestedRulesFitLimits() {
        XCTAssertLessThanOrEqual(WritingPreferences.suggestedRules.count, WritingPreferences.maxRules)
        XCTAssertTrue(WritingPreferences.suggestedRules.allSatisfy { rule in
            WritingPreferences.normalizedRule(rule).count <= WritingPreferences.maxRuleCharacters
        })
    }
}
