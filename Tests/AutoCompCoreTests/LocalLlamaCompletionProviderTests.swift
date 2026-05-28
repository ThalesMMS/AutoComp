import AutoCompCore
import XCTest

final class LocalLlamaCompletionProviderTests: XCTestCase {
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

    private func makeContext(
        focusedElementID: String = "field",
        textBeforeCursor: String = "Can you ",
        textAfterCursor: String? = nil
    ) -> TextContext {
        TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: focusedElementID,
            textBeforeCursor: textBeforeCursor,
            textAfterCursor: textAfterCursor
        )
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
    let loadError: Error?
    let appliesStopSequences: Bool
    private(set) var loadCount = 0
    private(set) var generateCount = 0
    private(set) var shutdownCount = 0
    private(set) var resetCount = 0
    private var paths: [String] = []
    private var runtimeEvents: [String] = []
    private var storedRequest: CompletionRequest?

    init(rawText: String = "review this", loadError: Error? = nil, appliesStopSequences: Bool = false) {
        self.rawText = rawText
        self.loadError = loadError
        self.appliesStopSequences = appliesStopSequences
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
