@testable import AutoCompCore
import XCTest

final class PromptPreparationTests: XCTestCase {
    func testPreparedContextFeedsPromptAndRequestFieldsFromSameValues() {
        let context = TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: "0123456789",
            textAfterCursor: "ABCDEFGHIJ",
            selectedText: "selection",
            fullTextWindow: "0123456789ABCDEFGHIJ"
        )
        let builder = PromptBuilder(maxContextCharacters: 4)
        let prepared = builder.prepare(context)

        XCTAssertEqual(prepared.mode, .fillInMiddle)
        XCTAssertEqual(prepared.textBeforeCursor, "6789")
        XCTAssertEqual(prepared.textAfterCursor, "ABCD")
        XCTAssertEqual(prepared.selectedText, "sele")
        XCTAssertEqual(prepared.fullTextWindow, "0123")
        XCTAssertEqual(
            builder.prompt(
                for: context,
                preparedContext: prepared,
                privacySettings: PrivacySettings(),
                visualContext: nil,
                clipboardContext: nil,
                personalizationSamples: []
            ),
            builder.prompt(for: context)
        )
    }

    func testSharedWhitespaceNormalizerPreservesTextWhileCollapsingRuns() {
        XCTAssertEqual(
            TextWhitespaceNormalizer.collapse("one\n\t two   three"),
            "one two three"
        )
    }

    func testSharedWhitespaceNormalizerTrimsUnicodeWhitespaceAndCapsLength() {
        XCTAssertEqual(
            TextWhitespaceNormalizer.normalize("\u{00A0}one\u{2003}\n two \u{00A0}", maxCharacters: 7),
            "one two"
        )
        XCTAssertEqual(
            TextWhitespaceNormalizer.normalize("one two three", maxCharacters: 8),
            "one two"
        )
    }

    func testSystemPromptsCoverContinuationAndFillInMiddle() {
        XCTAssertEqual(
            CompletionSystemPrompts.prompt(for: .continuation),
            CompletionSystemPrompts.continuation
        )
        XCTAssertEqual(
            CompletionSystemPrompts.prompt(for: .fillInMiddle),
            CompletionSystemPrompts.fillInMiddle
        )
        XCTAssertNotEqual(CompletionSystemPrompts.continuation, CompletionSystemPrompts.fillInMiddle)
    }
}
