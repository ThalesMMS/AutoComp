import AutoCompCore
import XCTest

final class SuggestionTextNormalizerTests: XCTestCase {
    func testRemovesCompletionLabelVariants() {
        let normalized = SuggestionTextNormalizer.normalize(
            rawText: "  Completion: review this",
            precedingText: "Can you "
        )

        XCTAssertEqual(normalized, "review this")
    }

    func testRemovesMarkdownFenceWrapper() {
        let normalized = SuggestionTextNormalizer.normalize(
            rawText: "```text\nreview this\n```",
            precedingText: "Can you "
        )

        XCTAssertEqual(normalized, "review this")
    }

    func testRemovesInlineBacktickWrapper() {
        let normalized = SuggestionTextNormalizer.normalize(
            rawText: "`review this`",
            precedingText: "Can you "
        )

        XCTAssertEqual(normalized, "review this")
    }

    func testRemovesExplanatoryPreambleBeforeCompletion() {
        let normalized = SuggestionTextNormalizer.normalize(
            rawText: "Sure, here's the completion:\nreview this",
            precedingText: "Can you "
        )

        XCTAssertEqual(normalized, "review this")
    }

    func testRemovesPrecedingTextEchoAtStart() {
        let normalized = SuggestionTextNormalizer.normalize(
            rawText: "Can you review this",
            precedingText: "Can you "
        )

        XCTAssertEqual(normalized, "review this")
    }

    func testRemovesPromptEchoCandidate() {
        let normalized = SuggestionTextNormalizer.normalize(
            rawText: "Prompt preview\nactual completion",
            precedingText: "Can you",
            promptEchoCandidates: ["Prompt preview"]
        )

        XCTAssertEqual(normalized, "actual completion")
    }

    func testRemovesTemplateMarkersBeforeCompletion() {
        let normalized = SuggestionTextNormalizer.normalize(
            rawText: "<|assistant|>\ncontinue the sentence",
            precedingText: "Please "
        )

        XCTAssertEqual(normalized, "continue the sentence")
    }

    func testUsesFirstUsefulLine() {
        let normalized = SuggestionTextNormalizer.normalize(
            rawText: "\n\nfirst line\nsecond line",
            precedingText: "Please "
        )

        XCTAssertEqual(normalized, "first line")
    }

    func testDropsLeadingWhitespaceWhenPrecedingTextEndsWhitespace() {
        let normalized = SuggestionTextNormalizer.normalize(
            rawText: " continue this",
            precedingText: "Please "
        )

        XCTAssertEqual(normalized, "continue this")
    }

    func testDoesNotDropLeadingNewlineWhenOnlyWhitespaceShouldBeRemoved() {
        let normalized = SuggestionTextNormalizer.normalize(
            rawText: " \u{2028}continue this",
            precedingText: "Please "
        )

        XCTAssertEqual(normalized, "\u{2028}continue this")
    }

    func testPreservesLeadingWhitespaceWhenPrecedingTextDoesNotEndWhitespace() {
        let normalized = SuggestionTextNormalizer.normalize(
            rawText: " continue this",
            precedingText: "Please"
        )

        XCTAssertEqual(normalized, " continue this")
    }

    func testReturnsEmptyForOnlyMarkersEchoAndWhitespace() {
        let normalized = SuggestionTextNormalizer.normalize(
            rawText: "Completion:\n\n",
            precedingText: "Please "
        )

        XCTAssertEqual(normalized, "")
    }

    func testReturnsEmptyForOnlyPrecedingTextEcho() {
        let normalized = SuggestionTextNormalizer.normalize(
            rawText: "Please ",
            precedingText: "Please "
        )

        XCTAssertEqual(normalized, "")
    }

    func testRejectsTrailingTextOnlyEcho() {
        let normalized = SuggestionTextNormalizer.normalize(
            rawText: "already there",
            precedingText: "Please ",
            trailingText: "already there"
        )

        XCTAssertEqual(normalized, "")
    }

    func testRemovesTrailingTextEchoSuffix() {
        let normalized = SuggestionTextNormalizer.normalize(
            rawText: "finish already there",
            precedingText: "Please ",
            trailingText: "already there"
        )

        XCTAssertEqual(normalized, "finish")
    }

    func testRemovesSuffixEchoFromFillInMiddleCompletion() {
        let normalized = SuggestionTextNormalizer.normalize(
            rawText: "adiada para sexta-feira porque o prazo mudou.",
            precedingText: "A reuniao foi ",
            trailingText: " porque o prazo mudou."
        )

        XCTAssertEqual(normalized, "adiada para sexta-feira")
    }

    func testRemovesFillInMiddleMarkersBeforeCompletion() {
        let normalized = SuggestionTextNormalizer.normalize(
            rawText: "<|fim_middle|>\nadiada para sexta-feira",
            precedingText: "A reuniao foi ",
            trailingText: " porque o prazo mudou."
        )

        XCTAssertEqual(normalized, "adiada para sexta-feira")
    }

    func testRequestOverloadUsesPromptEchoCandidatesAndFimSuffix() {
        let context = TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: "A reuniao foi ",
            textAfterCursor: " porque o prazo mudou."
        )
        let request = CompletionRequestFactory().makeRequest(
            for: context,
            configuration: RemoteCompletionConfiguration(
                baseURL: "http://127.0.0.1:8000",
                apiKey: "test",
                model: "default"
            )
        )

        let normalized = SuggestionTextNormalizer.normalize(
            rawText: "\(request.prompt)\n```text\nadiada para sexta-feira porque o prazo mudou.\n```",
            request: request
        )

        XCTAssertEqual(normalized, "adiada para sexta-feira")
    }
}
