import AutoCompCore
import XCTest

final class LocalLlamaCompletionProviderTests: XCTestCase {
    func testStreamingNormalizesAccumulatedRuntimePartialsAndMarksFinal() async throws {
        let modelURL = try makeTemporaryModelFile()
        let backend = FakeLocalLlamaRuntimeBackend(streamTexts: ["hel", "hello"])
        let provider = LocalLlamaCompletionProvider(
            configuration: LocalLlamaConfiguration(modelPath: modelURL.path),
            runtime: LocalLlamaRuntimeCore(backend: backend)
        )
        let context = makeContext()
        let metadata = StreamingCompletionMetadata(
            traceContext: CompletionTraceContext(),
            workID: 9,
            requestedRoute: .localLlama
        )
        let request = ProviderInvocation.Request(context: context)
        var partials: [CompletionPartial] = []

        for try await partial in provider.streamCompletion(request: request, metadata: metadata) {
            partials.append(partial)
        }

        XCTAssertEqual(partials.map(\.accumulatedText), ["hel", "hello"])
        XCTAssertEqual(partials.map(\.providerSequence), [1, 2])
        XCTAssertEqual(partials.map(\.phase), [.partial, .final])
        XCTAssertEqual(partials.map(\.metadata), [metadata, metadata])
    }

    func testUnavailableRuntimeBackendExposesOptionalBuildDiagnostic() async throws {
        let modelURL = try makeTemporaryModelFile()
        let backend = UnavailableLocalLlamaRuntimeBackend()
        let runtime = LocalLlamaRuntimeCore(backend: backend)

        XCTAssertEqual(backend.fallbackDiagnostic.classification, .optionalBuildFeature)
        XCTAssertEqual(backend.fallbackDiagnostic.reason, "llama-runtime-not-linked")
        XCTAssertEqual(backend.fallbackDiagnostic.userMessage, "Local Llama runtime is unavailable in this build.")

        do {
            try await runtime.load(configuration: LocalLlamaConfiguration(modelPath: modelURL.path))
            XCTFail("Expected runtime unavailable")
        } catch let error as LocalLlamaError {
            XCTAssertEqual(error, .runtimeUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let failedStatus = await runtime.status()
        XCTAssertEqual(
            failedStatus,
            LocalLlamaRuntimeStatus(
                state: .failed,
                modelPath: modelURL.path,
                message: backend.fallbackDiagnostic.userMessage
            )
        )
    }

    func testLoadedModelIsReusedWhenModelFileDisappears() async throws {
        let modelURL = try makeTemporaryModelFile()
        let backend = FakeLocalLlamaRuntimeBackend(rawText: "Completion:\n still works")
        let provider = LocalLlamaCompletionProvider(
            configuration: LocalLlamaConfiguration(modelPath: modelURL.path),
            runtime: LocalLlamaRuntimeCore(backend: backend)
        )

        _ = try await provider.complete(context: makeContext())
        try FileManager.default.removeItem(at: modelURL)
        let suggestion = try await provider.complete(context: makeContext())

        XCTAssertEqual(suggestion.visibleText, "still works")
        let counts = await backend.counts()
        XCTAssertEqual(counts.load, 1)
        XCTAssertEqual(counts.generate, 2)
    }

    func testRuntimeLoadErrorIsSurfaced() async throws {
        let modelURL = try makeTemporaryModelFile()
        let provider = LocalLlamaCompletionProvider(
            configuration: LocalLlamaConfiguration(modelPath: modelURL.path),
            runtime: LocalLlamaRuntimeCore(
                backend: FakeLocalLlamaRuntimeBackend(loadError: LocalLlamaError.loadFailed("bad model"))
            )
        )

        do {
            _ = try await provider.complete(context: makeContext())
            XCTFail("Expected load error")
        } catch let error as LocalLlamaError {
            XCTAssertEqual(error, .loadFailed("bad model"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testRuntimeAllocationErrorIsSurfacedWithoutCrash() async throws {
        let modelURL = try makeTemporaryModelFile()
        let provider = LocalLlamaCompletionProvider(
            configuration: LocalLlamaConfiguration(modelPath: modelURL.path),
            runtime: LocalLlamaRuntimeCore(
                backend: FakeLocalLlamaRuntimeBackend(
                    loadError: LocalLlamaError.allocationFailed("Could not allocate model wrapper.")
                )
            )
        )

        do {
            _ = try await provider.complete(context: makeContext())
            XCTFail("Expected allocation error")
        } catch let error as LocalLlamaError {
            XCTAssertEqual(error, .allocationFailed("Could not allocate model wrapper."))
            XCTAssertEqual(
                error.errorDescription,
                "Local model allocation failed: Could not allocate model wrapper."
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testGeneratedTextIsNormalizedIntoSuggestion() async throws {
        let modelURL = try makeTemporaryModelFile()
        let backend = FakeLocalLlamaRuntimeBackend(rawText: "Completion:\n review this today\nignore")
        let provider = LocalLlamaCompletionProvider(
            configuration: LocalLlamaConfiguration(modelPath: modelURL.path, maxTokens: 7),
            runtime: LocalLlamaRuntimeCore(backend: backend)
        )

        let suggestion = try await provider.complete(context: makeContext())

        XCTAssertEqual(suggestion.visibleText, "review this today")
        let counts = await backend.counts()
        XCTAssertEqual(counts.load, 1)
        XCTAssertEqual(counts.generate, 1)
        let request = await backend.lastRequest()
        XCTAssertEqual(request?.maxTokens, 7)
    }

    func testGeneratedFillInMiddleTextIsNormalizedWithSuffix() async throws {
        let modelURL = try makeTemporaryModelFile()
        let backend = FakeLocalLlamaRuntimeBackend(
            rawText: "```text\nadiada para sexta-feira porque o prazo mudou.\n```"
        )
        let provider = LocalLlamaCompletionProvider(
            configuration: LocalLlamaConfiguration(modelPath: modelURL.path),
            runtime: LocalLlamaRuntimeCore(backend: backend)
        )

        let suggestion = try await provider.complete(
            context: makeContext(
                textBeforeCursor: "A reuniao foi ",
                textAfterCursor: " porque o prazo mudou."
            )
        )

        XCTAssertEqual(suggestion.visibleText, "adiada para sexta-feira")
    }

    func testLocalGenerationReceivesAndAppliesStopSequences() async throws {
        let modelURL = try makeTemporaryModelFile()
        let backend = FakeLocalLlamaRuntimeBackend(
            rawText: "review this today\nignore this line",
            appliesStopSequences: true
        )
        let provider = LocalLlamaCompletionProvider(
            configuration: LocalLlamaConfiguration(
                modelPath: modelURL.path,
                stopSequences: CompletionStopSequences(
                    continuation: ["\n"],
                    fillInMiddle: ["<|fim_suffix|>"]
                )
            ),
            runtime: LocalLlamaRuntimeCore(backend: backend)
        )

        let suggestion = try await provider.complete(context: makeContext())

        XCTAssertEqual(suggestion.visibleText, "review this today")
        let request = await backend.lastRequest()
        XCTAssertEqual(request?.stopSequences, ["\n"])
    }

    func testLocalGenerationStopsByPromptTag() async throws {
        let modelURL = try makeTemporaryModelFile()
        let backend = FakeLocalLlamaRuntimeBackend(
            rawText: "adiada para sexta-feira<|fim_suffix|> porque o prazo mudou.",
            appliesStopSequences: true
        )
        let provider = LocalLlamaCompletionProvider(
            configuration: LocalLlamaConfiguration(
                modelPath: modelURL.path,
                stopSequences: CompletionStopSequences(
                    continuation: [],
                    fillInMiddle: ["<|fim_suffix|>"]
                )
            ),
            runtime: LocalLlamaRuntimeCore(backend: backend)
        )

        let suggestion = try await provider.complete(
            context: makeContext(
                textBeforeCursor: "A reuniao foi ",
                textAfterCursor: " porque o prazo mudou."
            )
        )

        XCTAssertEqual(suggestion.visibleText, "adiada para sexta-feira")
        let request = await backend.lastRequest()
        XCTAssertEqual(request?.stopSequences, ["<|fim_suffix|>"])
    }

    func testRuntimeCoreSkipsSameModelReloadAndReloadsAfterModelChangeOrShutdown() async throws {
        let firstModelURL = try makeTemporaryModelFile()
        let secondModelURL = try makeTemporaryModelFile()
        let backend = FakeLocalLlamaRuntimeBackend()
        let runtime = LocalLlamaRuntimeCore(backend: backend)

        try await runtime.load(configuration: LocalLlamaConfiguration(modelPath: firstModelURL.path))
        try await runtime.load(configuration: LocalLlamaConfiguration(modelPath: firstModelURL.path))
        try await runtime.load(configuration: LocalLlamaConfiguration(modelPath: secondModelURL.path))
        await runtime.shutdown()
        try await runtime.load(configuration: LocalLlamaConfiguration(modelPath: secondModelURL.path))

        let paths = await backend.loadedModelPaths()
        XCTAssertEqual(paths, [firstModelURL.path, secondModelURL.path, secondModelURL.path])
        let counts = await backend.counts()
        XCTAssertEqual(counts.load, 3)
        XCTAssertEqual(counts.shutdown, 2)
        let events = await backend.events()
        XCTAssertEqual(events, [
            "load:\(firstModelURL.path)",
            "shutdown",
            "load:\(secondModelURL.path)",
            "shutdown",
            "load:\(secondModelURL.path)"
        ])
    }

    func testRuntimeCoreReportsLoadStateTransitions() async throws {
        let modelURL = try makeTemporaryModelFile()
        let backend = FakeLocalLlamaRuntimeBackend()
        let runtime = LocalLlamaRuntimeCore(backend: backend)

        let initialStatus = await runtime.status()
        XCTAssertEqual(initialStatus, .unloaded)

        try await runtime.load(configuration: LocalLlamaConfiguration(modelPath: modelURL.path))

        let loadedStatus = await runtime.status()
        XCTAssertEqual(
            loadedStatus,
            LocalLlamaRuntimeStatus(state: .loaded, modelPath: modelURL.path)
        )

        await runtime.shutdown()

        let unloadedStatus = await runtime.status()
        XCTAssertEqual(
            unloadedStatus,
            LocalLlamaRuntimeStatus(state: .unloaded, modelPath: modelURL.path)
        )
    }

    func testRuntimeCoreReportsFailedLoadState() async throws {
        let modelURL = try makeTemporaryModelFile()
        let runtime = LocalLlamaRuntimeCore(
            backend: FakeLocalLlamaRuntimeBackend(loadError: LocalLlamaError.loadFailed("bad model"))
        )

        do {
            try await runtime.load(configuration: LocalLlamaConfiguration(modelPath: modelURL.path))
            XCTFail("Expected load failure")
        } catch let error as LocalLlamaError {
            XCTAssertEqual(error, .loadFailed("bad model"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        let failedStatus = await runtime.status()
        XCTAssertEqual(
            failedStatus,
            LocalLlamaRuntimeStatus(
                state: .failed,
                modelPath: modelURL.path,
                message: "Local model failed to load: bad model"
            )
        )
    }

    func testProviderRecordsRuntimeLoadStates() async throws {
        let modelURL = try makeTemporaryModelFile()
        let recorder = RuntimeStatusRecorder()
        let provider = LocalLlamaCompletionProvider(
            configuration: LocalLlamaConfiguration(modelPath: modelURL.path),
            runtime: LocalLlamaRuntimeCore(backend: FakeLocalLlamaRuntimeBackend()),
            runtimeStatusRecorder: { status in
                await recorder.record(status)
            }
        )

        _ = try await provider.complete(context: makeContext())
        await provider.shutdown()

        let statuses = await recorder.statuses()
        XCTAssertEqual(statuses, [
            LocalLlamaRuntimeStatus(state: .loading, modelPath: modelURL.path),
            LocalLlamaRuntimeStatus(state: .loaded, modelPath: modelURL.path),
            LocalLlamaRuntimeStatus(state: .unloaded, modelPath: modelURL.path)
        ])
    }

    func testPromptCacheHintTrackerResetsWhenFieldChanges() async throws {
        let modelURL = try makeTemporaryModelFile()
        let backend = FakeLocalLlamaRuntimeBackend()
        let provider = LocalLlamaCompletionProvider(
            configuration: LocalLlamaConfiguration(modelPath: modelURL.path),
            runtime: LocalLlamaRuntimeCore(backend: backend)
        )

        _ = try await provider.complete(context: makeContext(focusedElementID: "field-a"))
        _ = try await provider.complete(context: makeContext(focusedElementID: "field-a"))
        _ = try await provider.complete(context: makeContext(focusedElementID: "field-b"))

        let counts = await backend.counts()
        XCTAssertEqual(counts.load, 1)
        XCTAssertEqual(counts.generate, 3)
        XCTAssertEqual(counts.reset, 1)
    }

    func testPromptCacheHintTrackerClassifiesConfigurationAndModelChanges() async {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let context = TextContext(
            app: app,
            focusedElementID: "field",
            textBeforeCursor: "Can you "
        )
        let tracker = LlamaPromptCacheHintTracker()

        let initial = await tracker.observe(
            context: context,
            configuration: LocalLlamaConfiguration(modelPath: "/tmp/first.gguf", maxTokens: 16)
        )
        let same = await tracker.observe(
            context: context,
            configuration: LocalLlamaConfiguration(modelPath: "/tmp/first.gguf", maxTokens: 16)
        )
        let settingsChanged = await tracker.observe(
            context: context,
            configuration: LocalLlamaConfiguration(modelPath: "/tmp/first.gguf", maxTokens: 32)
        )
        let modelChanged = await tracker.observe(
            context: context,
            configuration: LocalLlamaConfiguration(modelPath: "/tmp/second.gguf", maxTokens: 32)
        )

        XCTAssertNil(initial)
        XCTAssertNil(same)
        XCTAssertEqual(settingsChanged, .configurationChanged)
        XCTAssertEqual(modelChanged, .modelChanged)
    }

    func testPromptCacheSignatureClassifiesEveryRuntimeCompatibilityDimension() {
        let context = makeContext()
        let local = LocalLlamaConfiguration(modelPath: "/tmp/model.gguf", maxTokens: 16)
        let remote = RemoteCompletionConfiguration(
            baseURL: "local://in-process",
            apiKey: "local",
            model: "local-llama",
            maxTokens: 16,
            stopSequences: CompletionStopSequences(continuation: ["\n"], fillInMiddle: ["<fim>"])
        )
        let request = CompletionRequestFactory(temperature: 0.2).makeRequest(
            for: context,
            configuration: remote
        )
        let base = LlamaPromptCache(
            context: context,
            configuration: local,
            request: request,
            tokenizerSignature: "tokenizer-a",
            rendererVersion: "renderer-a",
            decoderCapabilities: "decoder-a",
            privacySettings: PrivacySettings()
        )

        func signature(
            context nextContext: TextContext = context,
            local nextLocal: LocalLlamaConfiguration = local,
            request nextRequest: CompletionRequest? = request,
            tokenizer: String? = "tokenizer-a",
            renderer: String = "renderer-a",
            decoder: String = "decoder-a",
            privacy: PrivacySettings = PrivacySettings()
        ) -> LlamaPromptCache {
            LlamaPromptCache(
                context: nextContext,
                configuration: nextLocal,
                request: nextRequest,
                tokenizerSignature: tokenizer,
                rendererVersion: renderer,
                decoderCapabilities: decoder,
                privacySettings: privacy
            )
        }

        XCTAssertNil(signature().resetReason(comparedTo: base))
        XCTAssertEqual(signature(tokenizer: "tokenizer-b").resetReason(comparedTo: base), .tokenizerChanged)
        XCTAssertEqual(signature(renderer: "renderer-b").resetReason(comparedTo: base), .rendererChanged)
        XCTAssertEqual(signature(decoder: "decoder-b").resetReason(comparedTo: base), .decoderCapabilitiesChanged)
        XCTAssertEqual(
            signature(privacy: PrivacySettings(clipboardContextEnabled: true)).resetReason(comparedTo: base),
            .privacyChanged
        )

        let fimContext = makeContext(textAfterCursor: "later")
        let fimRequest = CompletionRequestFactory(temperature: 0.2).makeRequest(
            for: fimContext,
            configuration: remote
        )
        XCTAssertEqual(
            signature(context: fimContext, request: fimRequest).resetReason(comparedTo: base),
            .requestModeChanged
        )

        let hotterRequest = CompletionRequestFactory(temperature: 0.7).makeRequest(
            for: context,
            configuration: remote
        )
        XCTAssertEqual(signature(request: hotterRequest).resetReason(comparedTo: base), .samplingChanged)

        let changedStops = CompletionRequestFactory(temperature: 0.2).makeRequest(
            for: context,
            configuration: RemoteCompletionConfiguration(
                baseURL: "local://in-process",
                apiKey: "local",
                model: "local-llama",
                maxTokens: 16,
                stopSequences: CompletionStopSequences(continuation: ["STOP"], fillInMiddle: ["<fim>"])
            )
        )
        XCTAssertEqual(signature(request: changedStops).resetReason(comparedTo: base), .stopPolicyChanged)
    }

    func testPromptCacheUsesStableFieldIdentityInsteadOfVolatileElementID() {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 7)
        let stable = StableFieldIdentity(app: app, role: "AXTextArea", focusChangeSequence: 11)
        let configuration = LocalLlamaConfiguration(modelPath: "/tmp/model.gguf")
        let first = LlamaPromptCache(
            context: makeContext(focusedElementID: "volatile-a", app: app, stableFieldIdentity: stable),
            configuration: configuration
        )
        let sameLogicalField = LlamaPromptCache(
            context: makeContext(focusedElementID: "volatile-b", app: app, stableFieldIdentity: stable),
            configuration: configuration
        )
        let nextField = LlamaPromptCache(
            context: makeContext(
                focusedElementID: "volatile-c",
                app: app,
                stableFieldIdentity: stable.withFocusChangeSequence(12)
            ),
            configuration: configuration
        )

        XCTAssertNil(sameLogicalField.resetReason(comparedTo: first))
        XCTAssertEqual(nextField.resetReason(comparedTo: sameLogicalField), .fieldChanged)
    }

    func testPromptCacheFieldEqualityIsTransitiveAndDistinguishesMissingIdentity() {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 7)
        let configuration = LocalLlamaConfiguration(modelPath: "/tmp/model.gguf")
        let unspecifiedRole = StableFieldIdentity(app: app)
        let textArea = StableFieldIdentity(app: app, role: "AXTextArea")
        let textField = StableFieldIdentity(app: app, role: "AXTextField")
        XCTAssertTrue(unspecifiedRole.matchesStableTarget(textArea))
        XCTAssertTrue(unspecifiedRole.matchesStableTarget(textField))
        XCTAssertFalse(textArea.matchesStableTarget(textField))

        let unspecified = LlamaPromptCache(
            context: makeContext(app: app, stableFieldIdentity: unspecifiedRole),
            configuration: configuration
        )
        let area = LlamaPromptCache(
            context: makeContext(app: app, stableFieldIdentity: textArea),
            configuration: configuration
        )
        let field = LlamaPromptCache(
            context: makeContext(app: app, stableFieldIdentity: textField),
            configuration: configuration
        )
        let missing = LlamaPromptCache(
            context: makeContext(app: app, stableFieldIdentity: nil),
            configuration: configuration
        )

        XCTAssertEqual(area.resetReason(comparedTo: unspecified), .fieldChanged)
        XCTAssertEqual(field.resetReason(comparedTo: unspecified), .fieldChanged)
        XCTAssertEqual(field.resetReason(comparedTo: area), .fieldChanged)
        XCTAssertEqual(missing.resetReason(comparedTo: unspecified), .fieldChanged)
    }

    private func makeTemporaryModelFile() throws -> URL {
        let url = temporaryDirectory().appendingPathComponent("\(UUID().uuidString).gguf")
        try Data("fake model".utf8).write(to: url)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: url)
        }
        return url
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoCompLocalLlamaTests", isDirectory: true)
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        try FileManager.default.createDirectory(
            at: temporaryDirectory(),
            withIntermediateDirectories: true
        )
    }
}

private actor FakeLocalLlamaRuntimeBackend: LocalLlamaRuntimeBackend {
    let rawText: String
    nonisolated let streamTexts: [String]?
    let loadError: Error?
    let appliesStopSequences: Bool
    private(set) var loadCount = 0
    private(set) var generateCount = 0
    private(set) var shutdownCount = 0
    private(set) var resetCount = 0
    private var paths: [String] = []
    private var runtimeEvents: [String] = []
    private var storedRequest: CompletionRequest?

    init(
        rawText: String = "review this",
        loadError: Error? = nil,
        appliesStopSequences: Bool = false,
        streamTexts: [String]? = nil
    ) {
        self.rawText = rawText
        self.loadError = loadError
        self.appliesStopSequences = appliesStopSequences
        self.streamTexts = streamTexts
    }

    func loadModel(configuration: LocalLlamaConfiguration) async throws {
        loadCount += 1
        paths.append(configuration.modelPath)
        runtimeEvents.append("load:\(configuration.modelPath)")
        if let loadError {
            throw loadError
        }
    }

    func generateCompletion(for request: CompletionRequest) async throws -> String {
        generateCount += 1
        storedRequest = request
        if appliesStopSequences {
            return CompletionStopSequenceTrimmer.trim(rawText, stopSequences: request.stopSequences)
        }
        return rawText
    }

    nonisolated func generateCompletionStream(
        for request: CompletionRequest
    ) -> AsyncThrowingStream<LocalLlamaRuntimePartial, Error> {
        guard let streamTexts else {
            return AsyncThrowingStream { continuation in
                Task {
                    do {
                        let text = try await self.generateCompletion(for: request)
                        continuation.yield(.init(rawAccumulatedText: text, providerSequence: 1, isFinal: true, latencyMs: 1))
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
        return AsyncThrowingStream { continuation in
            for (index, text) in streamTexts.enumerated() {
                continuation.yield(.init(
                    rawAccumulatedText: text,
                    providerSequence: index + 1,
                    isFinal: index == streamTexts.count - 1,
                    latencyMs: index + 1
                ))
            }
            continuation.finish()
        }
    }

    func resetPromptCache() async {
        resetCount += 1
    }

    func promptCacheStats() async -> LlamaPromptCacheStats {
        LlamaPromptCacheStats(
            hits: UInt64(resetCount),
            misses: UInt64(loadCount),
            resets: UInt64(resetCount),
            retainedPromptTokens: 3,
            contextTokens: 512
        )
    }

    func shutdown() async {
        shutdownCount += 1
        runtimeEvents.append("shutdown")
    }

    func counts() -> (load: Int, generate: Int, shutdown: Int, reset: Int) {
        (loadCount, generateCount, shutdownCount, resetCount)
    }

    func loadedModelPaths() -> [String] {
        paths
    }

    func events() -> [String] {
        runtimeEvents
    }

    func lastRequest() -> CompletionRequest? {
        storedRequest
    }
}

private actor RuntimeStatusRecorder {
    private var recordedStatuses: [LocalLlamaRuntimeStatus] = []

    func record(_ status: LocalLlamaRuntimeStatus) {
        recordedStatuses.append(status)
    }

    func statuses() -> [LocalLlamaRuntimeStatus] {
        recordedStatuses
    }
}
