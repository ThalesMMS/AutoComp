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

    func testRulesAndLanguageHintsShareUnicodeWhitespaceNormalization() {
        let preferences = WritingPreferences(
            enabled: true,
            rules: ["\u{00A0}Write\u{2003}objectively\n"],
            languageHints: ["\u{00A0}Portuguese\u{2003}(Brazil)\n"]
        )

        XCTAssertEqual(preferences.rules, ["Write objectively"])
        XCTAssertEqual(preferences.languageHints, ["Portuguese (Brazil)"])
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

    func testLanguageHintsNormalizeDedupeAndLimit() {
        let longHint = String(repeating: "p", count: 80)
        let preferences = WritingPreferences(
            enabled: true,
            languageHints: ["  Portuguese   (Brazil) ", "PORTUGUESE (BRAZIL)", longHint] + (0..<8).map { "Language \($0)" }
        )

        XCTAssertEqual(preferences.languageHints.first, "Portuguese (Brazil)")
        XCTAssertEqual(preferences.languageHints.count, WritingPreferences.maxLanguageHints)
        XCTAssertTrue(preferences.languageHints.allSatisfy { $0.count <= WritingPreferences.maxLanguageHintCharacters })
    }

    func testAddingAndRemovingLanguageHintPreservesDeduplication() {
        let preferences = WritingPreferences(enabled: true, languageHints: ["English"])
            .addingLanguageHint("english")
            .addingLanguageHint("Portuguese (Brazil)")
            .removingLanguageHint("ENGLISH")

        XCTAssertEqual(preferences.languageHints, ["Portuguese (Brazil)"])
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

    func testPromptPreviewIncludesLanguageHintsAsSoftPreference() {
        let preferences = WritingPreferences(
            enabled: true,
            rules: ["Write objectively"],
            languageHints: ["Portuguese (Brazil)", "English"]
        )

        let promptPreview = preferences.promptPreview ?? ""

        XCTAssertTrue(promptPreview.contains("Language hints: follow the surrounding text language first."))
        XCTAssertTrue(promptPreview.contains("If ambiguous, prefer: Portuguese (Brazil), English."))
        XCTAssertFalse(promptPreview.localizedCaseInsensitiveContains("always use"))
        XCTAssertFalse(promptPreview.localizedCaseInsensitiveContains("force"))
    }

    func testSuggestedRulesFitLimits() {
        XCTAssertLessThanOrEqual(WritingPreferences.suggestedRules.count, WritingPreferences.maxRules)
        XCTAssertTrue(WritingPreferences.suggestedRules.allSatisfy { rule in
            WritingPreferences.normalizedRule(rule).count <= WritingPreferences.maxRuleCharacters
        })
    }

    func testCatalogsExposeTypedRulesAndLanguageHintsWithinLimits() {
        XCTAssertEqual(WritingRulesCatalog.suggestedRules.map(\.text), WritingPreferences.suggestedRules)
        XCTAssertEqual(LanguageHintCatalog.suggestedHints.map(\.name), WritingPreferences.suggestedLanguageHints)
        XCTAssertLessThanOrEqual(WritingPreferences.suggestedLanguageHints.count, WritingPreferences.maxLanguageHints)
        XCTAssertTrue(WritingPreferences.suggestedLanguageHints.allSatisfy { hint in
            WritingPreferences.normalizedLanguageHint(hint).count <= WritingPreferences.maxLanguageHintCharacters
        })
    }
}
