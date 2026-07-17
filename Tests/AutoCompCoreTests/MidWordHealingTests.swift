import AutoCompCore
import XCTest

final class MidWordHealingTests: XCTestCase {
    func testPlannerFindsUnicodeStemWithoutSplittingGrapheme() {
        let decision = MidWordRegenerationPlanner().decision(
            textBeforeCursor: "Fígado de dimens",
            textAfterCursor: "ões preservadas"
        )
        XCTAssertEqual(decision, .plan(.init(
            head: "Fígado de ", requiredPrefix: "dimens", visibleStem: "dimens", suffix: "ões preservadas"
        )))

        let combining = MidWordRegenerationPlanner().decision(
            textBeforeCursor: "Cafe\u{301}", textAfterCursor: "teria"
        )
        guard case .plan(let plan) = combining else { return XCTFail("Expected combining-mark plan") }
        XCTAssertEqual(Array(plan.visibleStem), Array("Cafe\u{301}"))
    }

    func testPlannerSuppressesNumericAndRiskyIdentifierStems() {
        XCTAssertEqual(
            MidWordRegenerationPlanner().decision(textBeforeCursor: "value 123", textAfterCursor: "45"),
            .suppress(.numericStem)
        )
        XCTAssertEqual(
            MidWordRegenerationPlanner().decision(textBeforeCursor: "value foo_2", textAfterCursor: "bar"),
            .suppress(.riskyIdentifier)
        )
    }

    func testSuffixTruncatorSavesUsefulPrefixAtSafeBoundary() {
        let truncator = SuffixOverlapTruncator()
        XCTAssertEqual(
            truncator.truncate(candidate: "adicionais, ões preservadas", suffix: "ões preservadas"),
            .truncated("adicionais,", overlapCharacters: 15)
        )
        XCTAssertEqual(
            truncator.truncate(candidate: "texto preserv", suffix: "preservadas"),
            .truncated("texto", overlapCharacters: 7)
        )
        XCTAssertEqual(truncator.truncate(candidate: "preserv", suffix: "preservadas"), .suppress)
        XCTAssertEqual(truncator.truncate(candidate: "útilões preservadas", suffix: "ões preservadas"), .suppress)
    }

    func testReconcilerRequiresStemAndNeverReturnsDuplicatedSuffix() {
        let plan = MidWordRegenerationPlan(
            head: "Fígado de ", requiredPrefix: "dimens", visibleStem: "dimens", suffix: "ões preservadas"
        )
        XCTAssertEqual(
            MidWordCandidateReconciler().reconcile(
                candidate: "dimensões adicionais, ões preservadas", plan: plan
            ),
            .publish("ões adicionais,")
        )
        XCTAssertEqual(MidWordCandidateReconciler().reconcile(candidate: "outra", plan: plan), .suppress)
    }

    func testSeamValidatorRejectsUnsafeJoinsWhitespacePunctuationAndScript() {
        let validator = CompletionSeamValidator()
        XCTAssertEqual(validator.validate(candidate: "next", before: "word ", after: "tail"), .reject(.invalidAlphaNumericJoin))
        XCTAssertEqual(validator.validate(candidate: " text", before: "word ", after: nil), .reject(.duplicatedSpace))
        XCTAssertEqual(validator.validate(candidate: "!", before: "word", after: "!"), .reject(.repeatedPunctuation))
        XCTAssertEqual(validator.validate(candidate: "текст ", before: "latin ", after: nil), .reject(.incompatibleScript))
        XCTAssertEqual(validator.validate(candidate: "safe ", before: "latin ", after: "tail"), .allow)
    }

    func testLocalSuffixRerankerRequiresRealScoresAndHasBoundedWeight() {
        let candidates = [
            SuffixCompatibilityCandidate(index: 0, baseScore: 1, suffixLogProbability: -4),
            SuffixCompatibilityCandidate(index: 1, baseScore: 0.9, suffixLogProbability: 0)
        ]
        XCTAssertEqual(LocalSuffixCompatibilityReranker().ranked(candidates), candidates)
        XCTAssertEqual(
            LocalSuffixCompatibilityReranker(configuration: .init(enabled: true, weight: 0.15)).ranked(candidates).map(\.index),
            [1, 0]
        )
        let missingScore = [
            candidates[0],
            SuffixCompatibilityCandidate(index: 1, baseScore: 0.9, suffixLogProbability: nil)
        ]
        XCTAssertEqual(
            LocalSuffixCompatibilityReranker(configuration: .init(enabled: true)).ranked(missingScore),
            missingScore
        )
    }
}
