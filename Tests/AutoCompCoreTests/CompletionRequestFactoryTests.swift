import AutoCompCore
import XCTest

final class CompletionRequestFactoryTests: XCTestCase {
    func testRequestCarriesModelLimitsAndPrompt() {
        let context = makeContext(textBeforeCursor: "Can you review")
        let configuration = RemoteCompletionConfiguration(
            baseURL: "http://127.0.0.1:8000",
            apiKey: "test",
            model: "test-model",
            maxTokens: 12
        )

        let request = CompletionRequestFactory().makeRequest(
            for: context,
            configuration: configuration
        )

        XCTAssertEqual(request.contextID, context.id)
        XCTAssertEqual(request.app, context.app)
        XCTAssertEqual(request.domain, context.domain)
        XCTAssertEqual(request.model, "test-model")
        XCTAssertEqual(request.maxTokens, 12)
        XCTAssertEqual(request.temperature, 0.2)
        XCTAssertEqual(request.mode, .continuation)
        XCTAssertNil(request.truncatedTextAfterCursor)
        XCTAssertFalse(request.fimSuffixInjected)
        XCTAssertTrue(request.prompt.contains("Text before cursor:\nCan you review"))
        XCTAssertEqual(request.promptEchoCandidates.first, request.prompt)
    }

    func testRequestTracksTruncatedTextBeforeCursor() {
        let context = makeContext(textBeforeCursor: "0123456789")
        let configuration = RemoteCompletionConfiguration(
            baseURL: "http://127.0.0.1:8000",
            apiKey: "test",
            model: "test-model"
        )
        let factory = CompletionRequestFactory(
            promptBuilder: PromptBuilder(maxContextCharacters: 4)
        )

        let request = factory.makeRequest(for: context, configuration: configuration)

        XCTAssertEqual(request.truncatedTextBeforeCursor, "6789")
        XCTAssertTrue(request.prompt.contains("Text before cursor:\n6789"))
        XCTAssertFalse(request.prompt.contains("Text before cursor:\n0123456789"))
    }

    func testRequestUsesFillInMiddleModeWhenSuffixIsUseful() {
        let context = makeContext(
            textBeforeCursor: "A reuniao foi ",
            textAfterCursor: " porque o prazo mudou.",
            fullTextWindow: "A reuniao foi  porque o prazo mudou."
        )
        let configuration = RemoteCompletionConfiguration(
            baseURL: "http://127.0.0.1:8000",
            apiKey: "test",
            model: "test-model"
        )

        let request = CompletionRequestFactory().makeRequest(
            for: context,
            configuration: configuration
        )

        XCTAssertEqual(request.mode, .fillInMiddle)
        XCTAssertEqual(request.truncatedTextAfterCursor, " porque o prazo mudou.")
        XCTAssertEqual(request.truncatedFullTextWindow, "A reuniao foi  porque o prazo mudou.")
        XCTAssertTrue(request.fimSuffixInjected)
        XCTAssertTrue(request.prompt.contains("Request mode: fillInMiddle"))
        XCTAssertTrue(request.prompt.contains("FIM suffix injected: true"))
        XCTAssertTrue(request.prompt.contains("<|fim_prefix|>"))
        XCTAssertTrue(request.prompt.contains("<|fim_suffix|>"))
        XCTAssertTrue(request.prompt.contains("Text after cursor (suffix):\n porque o prazo mudou."))
        XCTAssertTrue(request.promptEchoCandidates.contains(" porque o prazo mudou."))
    }

    func testRequestUsesFillInMiddleModeWhenSelectionIsUseful() {
        let context = makeContext(
            textBeforeCursor: "A reuniao foi ",
            selectedText: "adiada",
            fullTextWindow: "A reuniao foi adiada"
        )
        let configuration = RemoteCompletionConfiguration(
            baseURL: "http://127.0.0.1:8000",
            apiKey: "test",
            model: "test-model"
        )

        let request = CompletionRequestFactory().makeRequest(
            for: context,
            configuration: configuration
        )

        XCTAssertEqual(request.mode, .fillInMiddle)
        XCTAssertNil(request.truncatedTextAfterCursor)
        XCTAssertEqual(request.truncatedSelectedText, "adiada")
        XCTAssertFalse(request.fimSuffixInjected)
        XCTAssertTrue(request.prompt.contains("Selected text to replace:\nadiada"))
    }

    func testRequestUsesSelectionReplacementWithSuffixContext() {
        let context = makeContext(
            textBeforeCursor: "A reuniao foi ",
            textAfterCursor: " porque o prazo mudou.",
            selectedText: "adiada",
            fullTextWindow: "A reuniao foi adiada porque o prazo mudou."
        )
        let configuration = RemoteCompletionConfiguration(
            baseURL: "http://127.0.0.1:8000",
            apiKey: "test",
            model: "test-model"
        )

        let request = CompletionRequestFactory().makeRequest(
            for: context,
            configuration: configuration
        )

        XCTAssertEqual(request.mode, .fillInMiddle)
        XCTAssertEqual(request.truncatedTextBeforeCursor, "A reuniao foi ")
        XCTAssertEqual(request.truncatedTextAfterCursor, " porque o prazo mudou.")
        XCTAssertEqual(request.truncatedSelectedText, "adiada")
        XCTAssertTrue(request.fimSuffixInjected)
        XCTAssertTrue(request.prompt.contains("Text after cursor (suffix):\n porque o prazo mudou."))
        XCTAssertTrue(request.prompt.contains("Selected text to replace:\nadiada"))
        XCTAssertTrue(request.promptEchoCandidates.contains("adiada"))
        XCTAssertTrue(request.promptEchoCandidates.contains(" porque o prazo mudou."))
    }

    func testRequestOmitsDisabledOptionalSources() {
        let context = makeContext(
            textBeforeCursor: "Hello",
            captureSources: [.accessibility, .clipboard, .screenOCR]
        )
        let configuration = RemoteCompletionConfiguration(
            baseURL: "http://127.0.0.1:8000",
            apiKey: "test",
            model: "test-model"
        )

        let request = CompletionRequestFactory().makeRequest(
            for: context,
            configuration: configuration,
            privacySettings: PrivacySettings()
        )

        XCTAssertEqual(request.allowedCaptureSources, Set([.accessibility]))
        XCTAssertTrue(request.prompt.contains("accessibility"))
        XCTAssertFalse(request.prompt.contains("clipboard"))
        XCTAssertFalse(request.prompt.contains("screenOCR"))
    }

    func testRequestPreservesEnabledOptionalSources() {
        let context = makeContext(
            textBeforeCursor: "Hello",
            captureSources: [.accessibility, .clipboard, .screenOCR]
        )
        let configuration = RemoteCompletionConfiguration(
            baseURL: "http://127.0.0.1:8000",
            apiKey: "test",
            model: "test-model"
        )
        let privacy = PrivacySettings(
            clipboardContextEnabled: true,
            screenContextEnabled: true
        )

        let request = CompletionRequestFactory().makeRequest(
            for: context,
            configuration: configuration,
            privacySettings: privacy
        )

        XCTAssertEqual(request.allowedCaptureSources, Set([.accessibility, .clipboard, .screenOCR]))
        XCTAssertTrue(request.prompt.contains("accessibility"))
        XCTAssertTrue(request.prompt.contains("clipboard"))
        XCTAssertTrue(request.prompt.contains("screenOCR"))
    }

    func testRequestWithoutVisualContextKeepsPromptShape() {
        let context = makeContext(textBeforeCursor: "Hello")
        let configuration = RemoteCompletionConfiguration(
            baseURL: "http://127.0.0.1:8000",
            apiKey: "test",
            model: "test-model"
        )

        let request = CompletionRequestFactory().makeRequest(
            for: context,
            configuration: configuration,
            privacySettings: PrivacySettings(screenContextEnabled: true)
        )

        XCTAssertNil(request.visualContext)
        XCTAssertFalse(request.prompt.contains("Visual context"))
        XCTAssertTrue(request.prompt.contains("Text before cursor:\nHello"))
    }

    func testRequestIncludesAllowedVisualContext() {
        let context = makeContext(textBeforeCursor: "Hello")
        let visualContext = VisualContextSnapshot(summary: "The visible document title is Budget Review.")
        let configuration = RemoteCompletionConfiguration(
            baseURL: "http://127.0.0.1:8000",
            apiKey: "test",
            model: "test-model"
        )

        let request = CompletionRequestFactory().makeRequest(
            for: context,
            configuration: configuration,
            privacySettings: PrivacySettings(screenContextEnabled: true),
            visualContext: visualContext
        )

        XCTAssertEqual(request.visualContext, visualContext)
        XCTAssertEqual(request.allowedCaptureSources, Set([.accessibility, .screenOCR]))
        XCTAssertTrue(request.prompt.contains("Visual context (delimited):"))
        XCTAssertTrue(request.prompt.contains("<visual_context>\nThe visible document title is Budget Review.\n</visual_context>"))
    }

    func testRequestDropsVisualContextWhenScreenContextDisabled() {
        let context = makeContext(textBeforeCursor: "Hello")
        let visualContext = VisualContextSnapshot(summary: "The visible document title is Budget Review.")
        let configuration = RemoteCompletionConfiguration(
            baseURL: "http://127.0.0.1:8000",
            apiKey: "test",
            model: "test-model"
        )

        let request = CompletionRequestFactory().makeRequest(
            for: context,
            configuration: configuration,
            privacySettings: PrivacySettings(screenContextEnabled: false),
            visualContext: visualContext
        )

        XCTAssertNil(request.visualContext)
        XCTAssertEqual(request.allowedCaptureSources, Set([.accessibility]))
        XCTAssertFalse(request.prompt.contains("Visual context"))
        XCTAssertFalse(request.prompt.contains("Budget Review"))
    }

    func testRequestIncludesClipboardContextWhenAllowed() {
        let context = makeContext(textBeforeCursor: "Please summarize the launch plan")
        let clipboardContext = ClipboardContextSnapshot(
            summary: "Launch plan\nUpdate onboarding",
            status: .included,
            captureSources: [.clipboard]
        )
        let configuration = RemoteCompletionConfiguration(
            baseURL: "http://127.0.0.1:8000",
            apiKey: "test",
            model: "test-model"
        )

        let request = CompletionRequestFactory().makeRequest(
            for: context,
            configuration: configuration,
            privacySettings: PrivacySettings(clipboardContextEnabled: true),
            clipboardContext: clipboardContext
        )

        XCTAssertEqual(request.clipboardContext, clipboardContext)
        XCTAssertTrue(request.allowedCaptureSources.contains(.clipboard))
        XCTAssertTrue(request.prompt.contains("Clipboard context:\nLaunch plan\nUpdate onboarding"))
    }

    func testRequestOmitsClipboardContextWhenPrivacyOff() {
        let context = makeContext(textBeforeCursor: "Please summarize the launch plan")
        let clipboardContext = ClipboardContextSnapshot(
            summary: "Launch plan\nUpdate onboarding",
            status: .included,
            captureSources: [.clipboard]
        )
        let configuration = RemoteCompletionConfiguration(
            baseURL: "http://127.0.0.1:8000",
            apiKey: "test",
            model: "test-model"
        )

        let request = CompletionRequestFactory().makeRequest(
            for: context,
            configuration: configuration,
            privacySettings: PrivacySettings(clipboardContextEnabled: false),
            clipboardContext: clipboardContext
        )

        XCTAssertNil(request.clipboardContext)
        XCTAssertFalse(request.allowedCaptureSources.contains(.clipboard))
        XCTAssertFalse(request.prompt.contains("Clipboard context:"))
        XCTAssertFalse(request.prompt.contains("Launch plan"))
    }

    func testRequestShowsClipboardOmissionReasonWithoutContent() {
        let context = makeContext(textBeforeCursor: "Please summarize the launch plan")
        let clipboardContext = ClipboardContextSnapshot(
            summary: "",
            status: .omittedNotRelevant,
            captureSources: []
        )
        let configuration = RemoteCompletionConfiguration(
            baseURL: "http://127.0.0.1:8000",
            apiKey: "test",
            model: "test-model"
        )

        let request = CompletionRequestFactory().makeRequest(
            for: context,
            configuration: configuration,
            privacySettings: PrivacySettings(clipboardContextEnabled: true),
            clipboardContext: clipboardContext
        )

        XCTAssertEqual(request.clipboardContext, clipboardContext)
        XCTAssertTrue(request.prompt.contains("Clipboard context:\n[clipboard omitted: not relevant]"))
    }

    func testRequestEchoCandidatesUseTruncatedClipboardTextInjectedIntoPrompt() {
        let context = makeContext(textBeforeCursor: "Please summarize")
        let clipboardContext = ClipboardContextSnapshot(
            summary: "CLIPBOARD-CONTEXT-LONG",
            status: .included,
            captureSources: [.clipboard]
        )
        let configuration = RemoteCompletionConfiguration(
            baseURL: "http://127.0.0.1:8000",
            apiKey: "test",
            model: "test-model"
        )
        let factory = CompletionRequestFactory(
            promptBuilder: PromptBuilder(budgets: PromptInputBudgets(
                continuationPrefixCharacters: 40,
                fimPrefixCharacters: 40,
                fimSuffixCharacters: 40,
                selectionCharacters: 40,
                clipboardCharacters: 4,
                visualContextCharacters: 40,
                fullTextWindowCharacters: 40
            ))
        )

        let request = factory.makeRequest(
            for: context,
            configuration: configuration,
            privacySettings: PrivacySettings(clipboardContextEnabled: true),
            clipboardContext: clipboardContext
        )

        XCTAssertEqual(request.clipboardContext?.summary, "CLIP")
        XCTAssertTrue(request.prompt.contains("Clipboard context:\nCLIP"))
        XCTAssertTrue(request.promptEchoCandidates.contains("CLIP"))
        XCTAssertFalse(request.prompt.contains("CLIPBOARD-CONTEXT-LONG"))
        XCTAssertFalse(request.promptEchoCandidates.contains("CLIPBOARD-CONTEXT-LONG"))
    }

    func testRequestStoresVisualContextAfterVisualBudget() {
        let context = makeContext(
            textBeforeCursor: "Please summarize",
            captureSources: [.accessibility, .screenOCR]
        )
        let visualContext = VisualContextSnapshot(
            summary: "VISIBLE-CONTEXT-LONG",
            captureSources: [.screenOCR]
        )
        let configuration = RemoteCompletionConfiguration(
            baseURL: "http://127.0.0.1:8000",
            apiKey: "test",
            model: "test-model"
        )
        let factory = CompletionRequestFactory(
            promptBuilder: PromptBuilder(budgets: PromptInputBudgets(
                continuationPrefixCharacters: 40,
                fimPrefixCharacters: 40,
                fimSuffixCharacters: 40,
                selectionCharacters: 40,
                clipboardCharacters: 40,
                visualContextCharacters: 7,
                fullTextWindowCharacters: 40
            ))
        )

        let request = factory.makeRequest(
            for: context,
            configuration: configuration,
            privacySettings: PrivacySettings(screenContextEnabled: true),
            visualContext: visualContext
        )

        XCTAssertEqual(request.visualContext?.summary, "VISIBLE")
        XCTAssertTrue(request.prompt.contains("<visual_context>\nVISIBLE\n</visual_context>"))
        XCTAssertFalse(request.prompt.contains("VISIBLE-CONTEXT-LONG"))
    }

    func testRequestResolvesStopSequencesForContinuationAndFillInMiddleModes() {
        let configuration = RemoteCompletionConfiguration(
            baseURL: "http://127.0.0.1:8000",
            apiKey: "test",
            model: "test-model",
            stopSequences: CompletionStopSequences(
                continuation: ["\n"],
                fillInMiddle: ["<|fim_suffix|>"]
            )
        )
        let factory = CompletionRequestFactory()

        let continuation = factory.makeRequest(
            for: makeContext(textBeforeCursor: "Please "),
            configuration: configuration
        )
        let fim = factory.makeRequest(
            for: makeContext(
                textBeforeCursor: "A reuniao foi ",
                textAfterCursor: " porque o prazo mudou."
            ),
            configuration: configuration
        )

        XCTAssertEqual(continuation.mode, .continuation)
        XCTAssertEqual(continuation.stopSequences, ["\n"])
        XCTAssertEqual(fim.mode, .fillInMiddle)
        XCTAssertEqual(fim.stopSequences, ["<|fim_suffix|>"])
    }

    private func makeContext(
        textBeforeCursor: String,
        textAfterCursor: String? = nil,
        selectedText: String? = nil,
        fullTextWindow: String? = nil,
        captureSources: Set<TextCaptureSource> = [.accessibility]
    ) -> TextContext {
        TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            domain: "example.com",
            focusedElementID: "field",
            textBeforeCursor: textBeforeCursor,
            textAfterCursor: textAfterCursor,
            selectedText: selectedText,
            fullTextWindow: fullTextWindow,
            captureSources: captureSources
        )
    }
}
