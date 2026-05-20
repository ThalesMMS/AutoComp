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
        XCTAssertFalse(request.prompt.contains("Visual context:"))
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
        XCTAssertTrue(request.prompt.contains("Visual context:\nThe visible document title is Budget Review."))
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
        XCTAssertFalse(request.prompt.contains("Visual context:"))
        XCTAssertFalse(request.prompt.contains("Budget Review"))
    }

    private func makeContext(
        textBeforeCursor: String,
        captureSources: Set<TextCaptureSource> = [.accessibility]
    ) -> TextContext {
        TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            domain: "example.com",
            focusedElementID: "field",
            textBeforeCursor: textBeforeCursor,
            captureSources: captureSources
        )
    }
}
