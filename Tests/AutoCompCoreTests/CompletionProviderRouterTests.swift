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
        XCTAssertEqual(suggestion.completionRoute?.requestedKind, .remote)
        XCTAssertEqual(suggestion.completionRoute?.deliveredKind, .remote)
        XCTAssertNil(suggestion.completionRoute?.fallbackErrorDescription)
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
        XCTAssertEqual(suggestion.completionRoute?.requestedKind, .localLlama)
        XCTAssertEqual(suggestion.completionRoute?.deliveredKind, .remote)
        XCTAssertTrue(suggestion.completionRoute?.fallbackErrorDescription?.contains("Local model was not found") == true)
    }

    func testLocalFailureDoesNotUseRemoteProviderWithoutExplicitFallback() async {
        let remoteProvider = CountingCompletionProvider(text: "remote fallback")
        let router = CompletionProviderRouter(
            activeKind: .localLlama,
            providers: [
                .localLlama: ThrowingCompletionProvider(error: LocalLlamaError.allocationFailed("limit exceeded")),
                .remote: remoteProvider
            ]
        )

        do {
            _ = try await router.complete(context: makeContext())
            XCTFail("Expected local failure")
        } catch let error as LocalLlamaError {
            XCTAssertEqual(error, .allocationFailed("limit exceeded"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let remoteCallCount = await remoteProvider.callCount()
        XCTAssertEqual(remoteCallCount, 0)
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
        XCTAssertEqual(suggestion.completionRoute?.requestedKind, .appleIntelligence)
        XCTAssertEqual(suggestion.completionRoute?.deliveredKind, .remote)
        XCTAssertEqual(
            suggestion.completionRoute?.fallbackErrorDescription,
            "Apple Intelligence completion is unavailable: not enabled"
        )
    }

    func testAppleIntelligenceUnavailableWithoutFallbackFailsClearly() async {
        let router = CompletionProviderRouter(
            activeKind: .appleIntelligence,
            providers: [
                .appleIntelligence: ThrowingCompletionProvider(
                    error: AppleFoundationModelError.unavailable("FoundationModels requires macOS 26.0 or newer.")
                )
            ]
        )

        do {
            _ = try await router.complete(context: makeContext())
            XCTFail("Expected unavailable Apple Intelligence error")
        } catch let error as AppleFoundationModelError {
            XCTAssertEqual(
                error.errorDescription,
                "Apple Intelligence completion is unavailable: FoundationModels requires macOS 26.0 or newer."
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRemoteBackendRequiresConsentBeforeCallingProvider() async {
        let provider = CountingCompletionProvider(text: "review this")
        let router = CompletionProviderRouter(
            activeKind: .remote,
            providers: [.remote: provider],
            remoteConsentChecker: FixedRemoteConsentChecker(allowedScopes: [])
        )

        do {
            _ = try await router.complete(context: makeContext())
            XCTFail("Expected remote consent error")
        } catch let error as CompletionProviderRouterError {
            XCTAssertEqual(error, .remoteConsentRequired(.remoteBackend))
            XCTAssertEqual(
                error.errorDescription,
                "Remote completion requires explicit consent before autocomplete text is sent."
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let callCount = await provider.callCount()
        XCTAssertEqual(callCount, 0)
    }

    func testRemoteFallbackRequiresSeparateConsentBeforeCallingProvider() async {
        let remoteProvider = CountingCompletionProvider(text: "remote fallback")
        let router = CompletionProviderRouter(
            activeKind: .localLlama,
            fallbackKind: .remote,
            providers: [
                .localLlama: ThrowingCompletionProvider(error: LocalLlamaError.modelNotFound("/tmp/missing.gguf")),
                .remote: remoteProvider
            ],
            remoteConsentChecker: FixedRemoteConsentChecker(allowedScopes: [.remoteBackend])
        )

        do {
            _ = try await router.complete(context: makeContext())
            XCTFail("Expected remote fallback consent error")
        } catch let error as CompletionProviderRouterError {
            XCTAssertEqual(error, .remoteConsentRequired(.remoteFallback))
            XCTAssertEqual(
                error.errorDescription,
                "Remote fallback requires explicit consent before autocomplete text is sent."
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let remoteCallCount = await remoteProvider.callCount()
        XCTAssertEqual(remoteCallCount, 0)
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

    func testPrepareForRuntimeSwitchForwardsToLifecycleProviders() async {
        let localProvider = LifecycleRecordingCompletionProvider(text: "local")
        let remoteProvider = StaticCompletionProvider(text: "remote")
        let router = CompletionProviderRouter(
            activeKind: .remote,
            providers: [
                .remote: remoteProvider,
                .localLlama: localProvider
            ]
        )

        await router.prepareForRuntimeSwitch()

        let prepareCount = await localProvider.prepareCount()
        XCTAssertEqual(prepareCount, 1)
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

private actor CountingCompletionProvider: CompletionProvider {
    let text: String
    private var storedCallCount = 0

    init(text: String) {
        self.text = text
    }

    func callCount() -> Int {
        storedCallCount
    }

    func complete(context: TextContext) async throws -> Suggestion {
        storedCallCount += 1
        return Suggestion(baseContextID: context.id, visibleText: text, latencyMs: 1)
    }
}

private actor LifecycleRecordingCompletionProvider: CompletionProvider, RuntimeSwitchPreparingCompletionProvider {
    let text: String
    private var storedPrepareCount = 0

    init(text: String) {
        self.text = text
    }

    func prepareCount() -> Int {
        storedPrepareCount
    }

    func prepareForRuntimeSwitch() async {
        storedPrepareCount += 1
    }

    func complete(context: TextContext) async throws -> Suggestion {
        Suggestion(baseContextID: context.id, visibleText: text, latencyMs: 1)
    }
}

private struct FixedRemoteConsentChecker: RemoteCompletionConsentChecking {
    let allowedScopes: Set<RemoteCompletionConsentScope>

    func hasConsent(for scope: RemoteCompletionConsentScope) -> Bool {
        allowedScopes.contains(scope)
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
