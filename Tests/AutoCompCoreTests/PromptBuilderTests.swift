import AutoCompCore
import XCTest

final class PromptBuilderTests: XCTestCase {
    func testPromptOmitsDisabledOptionalSources() {
        let context = TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: "Hello there",
            captureSources: [.accessibility, .clipboard, .screenOCR]
        )

        let prompt = PromptBuilder().prompt(for: context, privacySettings: PrivacySettings())

        XCTAssertTrue(prompt.contains("accessibility"))
        XCTAssertFalse(prompt.contains("clipboard"))
        XCTAssertFalse(prompt.contains("screenOCR"))
    }

    func testPromptRendersProvidedVisualContextWithoutRefiltering() {
        let context = TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: "Hello there"
        )
        let visualContext = VisualContextSnapshot(
            summary: "Visible title: Budget Review",
            captureSources: [.accessibility]
        )

        let prompt = PromptBuilder().prompt(
            for: context,
            privacySettings: PrivacySettings(screenContextEnabled: false),
            visualContext: visualContext
        )

        XCTAssertTrue(prompt.contains("Visual context (delimited):"))
        XCTAssertTrue(prompt.contains("<visual_context>\nVisible title: Budget Review\n</visual_context>"))
    }

    func testScreenOCRGeometrySourceDoesNotCreateVisualContextBlock() {
        let context = TextContext(
            app: AppIdentity(bundleID: "com.google.Chrome", displayName: "Chrome", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: "Authoritative AX text ",
            captureSources: [.accessibility, .screenOCR]
        )

        let prompt = PromptBuilder().prompt(
            for: context,
            privacySettings: PrivacySettings(screenContextEnabled: true)
        )

        XCTAssertTrue(prompt.contains("Context sources: accessibility, screenOCR"))
        XCTAssertTrue(prompt.contains("Text before cursor:\nAuthoritative AX text "))
        XCTAssertFalse(prompt.contains("Visual context (delimited):"))
        XCTAssertFalse(prompt.contains("<visual_context>"))
    }

    func testFillInMiddlePromptInstructsInsertionOnly() {
        let context = TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: "A reuniao foi ",
            textAfterCursor: " porque o prazo mudou.",
            selectedText: "adiada"
        )

        let prompt = PromptBuilder().prompt(for: context)

        XCTAssertTrue(prompt.contains("Return only the exact text to insert at the cursor"))
        XCTAssertTrue(prompt.contains("Do not repeat the prefix, suffix, selected text"))
        XCTAssertTrue(prompt.contains("Request mode: fillInMiddle"))
        XCTAssertTrue(prompt.contains("Text before cursor (prefix):\nA reuniao foi "))
        XCTAssertTrue(prompt.contains("Text after cursor (suffix):\n porque o prazo mudou."))
        XCTAssertTrue(prompt.contains("Selected text to replace:\nadiada"))
        XCTAssertTrue(prompt.contains("<|fim_middle|>"))
    }

    func testPromptIncludesClipboardOmissionReasonWhenClipboardIsNotRelevant() {
        let context = TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: "Please summarize the launch plan"
        )
        let clipboardContext = ClipboardContextSnapshot(
            summary: "",
            status: .omittedNotRelevant
        )

        let prompt = PromptBuilder().prompt(
            for: context,
            privacySettings: PrivacySettings(clipboardContextEnabled: true),
            clipboardContext: clipboardContext
        )

        XCTAssertTrue(prompt.contains("Clipboard context:\n[clipboard omitted: not relevant]"))
    }

    func testPromptDoesNotRenderClipboardContextWhenPrivacyIsOff() {
        let context = TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: "Please summarize the launch plan"
        )
        let clipboardContext = ClipboardContextSnapshot(
            summary: "Launch plan",
            status: .included,
            captureSources: [.clipboard]
        )

        let prompt = PromptBuilder().prompt(
            for: context,
            privacySettings: PrivacySettings(clipboardContextEnabled: false),
            clipboardContext: clipboardContext
        )

        XCTAssertFalse(prompt.contains("Clipboard context:"))
        XCTAssertFalse(prompt.contains("Launch plan"))
    }

    func testPromptIncludesWritingPreferencesOnlyWhenEnabled() {
        let context = TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: "Please "
        )
        let disabledPrompt = PromptBuilder().prompt(
            for: context,
            privacySettings: PrivacySettings(
                writingPreferences: WritingPreferences(enabled: false, rules: ["Write objectively"])
            )
        )
        let enabledPrompt = PromptBuilder().prompt(
            for: context,
            privacySettings: PrivacySettings(
                writingPreferences: WritingPreferences(
                    enabled: true,
                    rules: ["Write objectively", "Avoid emoji"]
                )
            )
        )

        XCTAssertFalse(disabledPrompt.contains("Writing preferences:"))
        XCTAssertTrue(enabledPrompt.contains("Writing preferences:\n- Write objectively\n- Avoid emoji"))
    }

    func testContinuationUsesContinuationPrefixBudget() {
        let context = TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: "0123456789"
        )
        let builder = PromptBuilder(budgets: PromptInputBudgets(
            continuationPrefixCharacters: 4,
            fimPrefixCharacters: 8,
            fimSuffixCharacters: 8,
            selectionCharacters: 8,
            clipboardCharacters: 8,
            visualContextCharacters: 8,
            fullTextWindowCharacters: 8
        ))

        let prompt = builder.prompt(for: context)

        XCTAssertEqual(builder.truncatedTextBeforeCursor(for: context), "6789")
        XCTAssertTrue(prompt.contains("Text before cursor:\n6789"))
        XCTAssertFalse(prompt.contains("Text before cursor:\n0123456789"))
    }

    func testFillInMiddleUsesSeparatePrefixSuffixAndSelectionBudgets() {
        let context = TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: "0123456789",
            textAfterCursor: "ABCDEFGHIJ",
            selectedText: "selected-text"
        )
        let builder = PromptBuilder(budgets: PromptInputBudgets(
            continuationPrefixCharacters: 10,
            fimPrefixCharacters: 3,
            fimSuffixCharacters: 4,
            selectionCharacters: 6,
            clipboardCharacters: 10,
            visualContextCharacters: 10,
            fullTextWindowCharacters: 10
        ))

        let prompt = builder.prompt(for: context)

        XCTAssertEqual(builder.truncatedTextBeforeCursor(for: context), "789")
        XCTAssertEqual(builder.truncatedTextAfterCursor(for: context), "ABCD")
        XCTAssertEqual(builder.truncatedSelectedText(for: context), "select")
        XCTAssertTrue(prompt.contains("Text before cursor (prefix):\n789"))
        XCTAssertTrue(prompt.contains("Text after cursor (suffix):\nABCD"))
        XCTAssertTrue(prompt.contains("Selected text to replace:\nselect"))
        XCTAssertFalse(prompt.contains("Text before cursor (prefix):\n0123456789"))
        XCTAssertFalse(prompt.contains("ABCDEFGHIJ"))
        XCTAssertFalse(prompt.contains("selected-text"))
    }

    func testClipboardAndVisualBudgetsDoNotDisplacePrimaryContext() {
        let context = TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: "primary-tail",
            captureSources: [.accessibility, .clipboard, .screenOCR]
        )
        let visualContext = VisualContextSnapshot(summary: "VISIBLE-CONTEXT-LONG")
        let clipboardContext = ClipboardContextSnapshot(
            summary: "CLIPBOARD-CONTEXT-LONG",
            status: .included,
            captureSources: [.clipboard]
        )
        let builder = PromptBuilder(budgets: PromptInputBudgets(
            continuationPrefixCharacters: 6,
            fimPrefixCharacters: 6,
            fimSuffixCharacters: 6,
            selectionCharacters: 6,
            clipboardCharacters: 5,
            visualContextCharacters: 4,
            fullTextWindowCharacters: 6
        ))

        let prompt = builder.prompt(
            for: context,
            privacySettings: PrivacySettings(
                clipboardContextEnabled: true,
                screenContextEnabled: true
            ),
            visualContext: visualContext,
            clipboardContext: clipboardContext
        )

        XCTAssertTrue(prompt.contains("Text before cursor:\ny-tail"))
        XCTAssertTrue(prompt.contains("<visual_context>\nVISI\n</visual_context>"))
        XCTAssertTrue(prompt.contains("Clipboard context:\nCLIPB"))
        XCTAssertFalse(prompt.contains("VISIBLE-CONTEXT-LONG"))
        XCTAssertFalse(prompt.contains("CLIPBOARD-CONTEXT-LONG"))
    }
}
