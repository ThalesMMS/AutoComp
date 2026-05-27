import AutoCompCore
import XCTest

final class SuggestionTests: XCTestCase {
    func testAcceptNextWordConsumesOneWordAtATime() {
        var suggestion = Suggestion(
            baseContextID: UUID(),
            visibleText: " hello world again",
            latencyMs: 10
        )

        XCTAssertEqual(suggestion.acceptNextWord(), " hello ")
        XCTAssertEqual(suggestion.acceptedPrefix, " hello ")
        XCTAssertEqual(suggestion.remainingText, "world again")

        XCTAssertEqual(suggestion.acceptNextWord(), "world ")
        XCTAssertEqual(suggestion.remainingText, "again")

        XCTAssertEqual(suggestion.acceptNextWord(), "again")
        XCTAssertTrue(suggestion.isExhausted)
    }

    func testAcceptNextWordAddsSpaceAfterTerminalPunctuationWhenModelOmittedIt() {
        var suggestion = Suggestion(
            baseContextID: UUID(),
            visibleText: " done.",
            latencyMs: 10
        )

        XCTAssertEqual(suggestion.acceptNextWord(), " done. ")
        XCTAssertEqual(suggestion.acceptedPrefix, " done. ")
        XCTAssertTrue(suggestion.isExhausted)
    }

    func testAcceptNextWordDoesNotDuplicateExistingSpaceAfterPunctuation() {
        var suggestion = Suggestion(
            baseContextID: UUID(),
            visibleText: " done. next",
            latencyMs: 10
        )

        XCTAssertEqual(suggestion.acceptNextWord(), " done. ")
        XCTAssertEqual(suggestion.remainingText, "next")
    }

    func testAutocompleteIsSuppressedAfterCompleteSentence() {
        XCTAssertTrue(TextContinuationHeuristics.shouldSuppressAutocomplete(after: "That works."))
        XCTAssertTrue(TextContinuationHeuristics.shouldSuppressAutocomplete(after: "That works.”"))
        XCTAssertTrue(TextContinuationHeuristics.shouldSuppressAutocomplete(after: "Isso funciona! "))
        XCTAssertFalse(TextContinuationHeuristics.shouldSuppressAutocomplete(after: "That works"))
        XCTAssertFalse(TextContinuationHeuristics.shouldSuppressAutocomplete(after: "That works,"))
    }

    func testAcceptNextWordAcceptsSelectedAlternativeForMultiSuggestion() {
        var suggestion = Suggestion(
            baseContextID: UUID(),
            visibleText: " first option",
            alternatives: [
                SuggestionAlternative(visibleText: " first option"),
                SuggestionAlternative(visibleText: " second option")
            ],
            selectedAlternativeIndex: 1,
            latencyMs: 10
        )

        XCTAssertEqual(suggestion.acceptNextWord(), " second option")
        XCTAssertTrue(suggestion.isExhausted)
        XCTAssertEqual(suggestion.acceptedPrefix, " second option")
    }
}
