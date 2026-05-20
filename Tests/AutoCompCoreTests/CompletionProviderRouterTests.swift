import AutoCompCore
import XCTest

final class CompletionProviderRouterTests: XCTestCase {
    func testRoutesRemoteProvider() async throws {
        let router = CompletionProviderRouter(
            activeKind: .remote,
            providers: [.remote: StaticCompletionProvider(text: "review this")]
        )

        let suggestion = try await router.complete(context: makeContext())

        XCTAssertEqual(suggestion.visibleText, "review this")
    }

    func testUnavailableModeFailsClearly() async {
        let router = CompletionProviderRouter(
            activeKind: .localLlama,
            providers: [.remote: StaticCompletionProvider(text: "review this")]
        )

        do {
            _ = try await router.complete(context: makeContext())
            XCTFail("Expected unavailable engine error")
        } catch let error as CompletionProviderRouterError {
            XCTAssertEqual(error, .unavailable(.localLlama))
            XCTAssertEqual(error.errorDescription, "Local Llama completion is unavailable in this build.")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFallsBackToRemoteProviderWhenConfigured() async throws {
        let router = CompletionProviderRouter(
            activeKind: .localLlama,
            fallbackKind: .remote,
            providers: [
                .localLlama: ThrowingCompletionProvider(error: LocalLlamaError.modelNotFound("/tmp/missing.gguf")),
                .remote: StaticCompletionProvider(text: "remote fallback")
            ]
        )

        let suggestion = try await router.complete(context: makeContext())

        XCTAssertEqual(suggestion.visibleText, "remote fallback")
    }

    func testFallsBackFromAppleIntelligenceWhenConfigured() async throws {
        let router = CompletionProviderRouter(
            activeKind: .appleIntelligence,
            fallbackKind: .remote,
            providers: [
                .appleIntelligence: ThrowingCompletionProvider(
                    error: AppleFoundationModelError.unavailable("not enabled")
                ),
                .remote: StaticCompletionProvider(text: "remote fallback")
            ]
        )

        let suggestion = try await router.complete(context: makeContext())

        XCTAssertEqual(suggestion.visibleText, "remote fallback")
    }

    func testForwardsVisualContextToAwareProvider() async throws {
        let provider = RecordingVisualCompletionProvider(text: "visual response")
        let router = CompletionProviderRouter(
            activeKind: .remote,
            providers: [.remote: provider]
        )
        let visualContext = VisualContextSnapshot(summary: "Visible title Budget Review")

        let suggestion = try await router.complete(
            context: makeContext(),
            privacySettings: PrivacySettings(screenContextEnabled: true),
            visualContext: visualContext
        )

        XCTAssertEqual(suggestion.visibleText, "visual response")
        let recordedVisualContext = await provider.recordedVisualContext()
        XCTAssertEqual(recordedVisualContext, visualContext)
    }

    private func makeContext() -> TextContext {
        TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: "Can you "
        )
    }
}

private actor StaticCompletionProvider: CompletionProvider {
    let text: String

    init(text: String) {
        self.text = text
    }

    func complete(context: TextContext) async throws -> Suggestion {
        Suggestion(baseContextID: context.id, visibleText: text, latencyMs: 1)
    }
}

private actor ThrowingCompletionProvider: CompletionProvider {
    let error: Error

    init(error: Error) {
        self.error = error
    }

    func complete(context: TextContext) async throws -> Suggestion {
        throw error
    }
}

private actor RecordingVisualCompletionProvider: VisualContextAwareCompletionProvider {
    let text: String
    private var storedVisualContext: VisualContextSnapshot?

    init(text: String) {
        self.text = text
    }

    func recordedVisualContext() -> VisualContextSnapshot? {
        storedVisualContext
    }

    func complete(context: TextContext) async throws -> Suggestion {
        try await complete(context: context, privacySettings: PrivacySettings(), visualContext: nil)
    }

    func complete(
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?
    ) async throws -> Suggestion {
        storedVisualContext = visualContext
        return Suggestion(baseContextID: context.id, visibleText: text, latencyMs: 1)
    }
}
