import AutoCompCore
@testable import AutoCompLlamaRuntime
import XCTest

final class LlamaCppRuntimeBackendTests: XCTestCase {
    func testBackendLifecycleFreesOnlyAfterLastRelease() {
        var initCount = 0
        var freeCount = 0
        let lifecycle = LlamaBackendGlobalLifecycle(
            initialize: { initCount += 1 },
            free: { freeCount += 1 }
        )

        lifecycle.retain()
        lifecycle.retain()
        XCTAssertEqual(initCount, 1)
        XCTAssertEqual(freeCount, 0)

        lifecycle.release()
        XCTAssertEqual(freeCount, 0)

        lifecycle.release()
        XCTAssertEqual(freeCount, 1)

        lifecycle.release()
        XCTAssertEqual(freeCount, 1)

        lifecycle.retain()
        XCTAssertEqual(initCount, 2)
        lifecycle.release()
        XCTAssertEqual(freeCount, 2)
    }

    func testRuntimeSystemInfoReportsLinkedRuntime() {
        let systemInfo = LlamaCppRuntimeBackend.runtimeSystemInfo()

        XCTAssertFalse(systemInfo.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        XCTAssertNotEqual(systemInfo, "unavailable")
    }

    func testMissingModelFileFailsClearly() async {
        let missingPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).gguf")
            .path
        let backend = LlamaCppRuntimeBackend(loadVocabularyOnly: true)

        do {
            try await backend.loadModel(configuration: LocalLlamaConfiguration(modelPath: missingPath))
            XCTFail("Expected missing model error")
        } catch let error as LocalLlamaError {
            XCTAssertEqual(error, .modelNotFound(missingPath))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testGenerationWithoutLoadedModelFailsClearly() async {
        let backend = LlamaCppRuntimeBackend(loadVocabularyOnly: true)

        do {
            _ = try await backend.generateCompletion(for: makeRequest())
            XCTFail("Expected generation error")
        } catch let error as LocalLlamaError {
            XCTAssertEqual(error, .runtimeUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStreamingWithoutLoadedModelFailsClearly() async {
        let backend = LlamaCppRuntimeBackend(loadVocabularyOnly: true)

        do {
            for try await _ in backend.generateCompletionStream(for: makeRequest()) {
                XCTFail("Expected no streamed partial")
            }
            XCTFail("Expected generation error")
        } catch let error as LocalLlamaError {
            XCTAssertEqual(error, .runtimeUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testTokenizerProfileWithoutLoadedModelFailsClearly() async {
        let backend = LlamaCppRuntimeBackend(loadVocabularyOnly: true)

        do {
            _ = try await backend.tokenizerProfile()
            XCTFail("Expected tokenizer profile error")
        } catch let error as LocalLlamaError {
            XCTAssertEqual(error, .runtimeUnavailable)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testModelAboveConfiguredMemoryLimitFailsBeforeLoading() async throws {
        let modelURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("oversized-\(UUID().uuidString).gguf")
        try Data(repeating: 0, count: 16).write(to: modelURL)
        defer {
            try? FileManager.default.removeItem(at: modelURL)
        }
        let backend = LlamaCppRuntimeBackend(loadVocabularyOnly: true)

        do {
            try await backend.loadModel(
                configuration: LocalLlamaConfiguration(
                    modelPath: modelURL.path,
                    maxRAMBytes: 4
                )
            )
            XCTFail("Expected memory limit error")
        } catch let error as LocalLlamaError {
            guard case .allocationFailed(let reason) = error else {
                return XCTFail("Expected allocation failure, got \(error)")
            }
            XCTAssertTrue(reason.contains("exceeds configured local memory limit"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testBridgeAllocationLoadFailureMapsToAllocationError() {
        let error = LlamaCppRuntimeBackend.loadError(
            message: "Could not allocate model wrapper.",
            code: 3
        )

        XCTAssertEqual(error, .allocationFailed("Could not allocate model wrapper."))
    }

    func testPromptCacheCompatibilityHitsForSharedPrefix() {
        let decision = LlamaPromptCacheCompatibility.evaluate(
            cachedTokens: [10, 11, 12],
            cachedMaxTokens: 12,
            cachedTemperature: 0.2,
            promptTokens: [10, 11, 15, 16],
            maxTokens: 12,
            temperature: 0.2
        )

        XCTAssertTrue(decision.canReuse)
        XCTAssertEqual(decision.commonPrefixTokens, 2)
    }

    func testPromptCacheCompatibilityMissesWithoutSharedPrefix() {
        let decision = LlamaPromptCacheCompatibility.evaluate(
            cachedTokens: [10, 11, 12],
            cachedMaxTokens: 12,
            cachedTemperature: 0.2,
            promptTokens: [20, 21, 22],
            maxTokens: 12,
            temperature: 0.2
        )

        XCTAssertFalse(decision.canReuse)
        XCTAssertEqual(decision.commonPrefixTokens, 0)
    }

    func testPromptCacheCompatibilityMissesWhenSamplingChanges() {
        let tokenDecision = LlamaPromptCacheCompatibility.evaluate(
            cachedTokens: [10, 11, 12],
            cachedMaxTokens: 12,
            cachedTemperature: 0.2,
            promptTokens: [10, 11, 12, 13],
            maxTokens: 16,
            temperature: 0.2
        )
        let temperatureDecision = LlamaPromptCacheCompatibility.evaluate(
            cachedTokens: [10, 11, 12],
            cachedMaxTokens: 12,
            cachedTemperature: 0.2,
            promptTokens: [10, 11, 12, 13],
            maxTokens: 12,
            temperature: 0.7
        )

        XCTAssertFalse(tokenDecision.canReuse)
        XCTAssertFalse(temperatureDecision.canReuse)
    }

    func testPromptCacheStatsAreEmptyBeforeModelLoadAndAfterShutdown() async {
        let backend = LlamaCppRuntimeBackend(loadVocabularyOnly: true)

        XCTAssertEqual(backend.cacheStats(), .empty)
        await backend.shutdown()
        XCTAssertEqual(backend.cacheStats(), .empty)
    }

    func testBridgeCacheMissEventsMapToSpecificSafeResetReasons() {
        XCTAssertNil(LlamaCppRuntimeBackend.cacheResetReason(event: 0))
        XCTAssertEqual(LlamaCppRuntimeBackend.cacheResetReason(event: 1), .coldStart)
        XCTAssertEqual(LlamaCppRuntimeBackend.cacheResetReason(event: 2), .noCommonPrefix)
        XCTAssertEqual(LlamaCppRuntimeBackend.cacheResetReason(event: 3), .contextSizeChanged)
        XCTAssertEqual(LlamaCppRuntimeBackend.cacheResetReason(event: 4), .samplingChanged)
        XCTAssertEqual(LlamaCppRuntimeBackend.cacheResetReason(event: 5), .runtimeInconsistency)
        XCTAssertNil(LlamaCppRuntimeBackend.cacheResetReason(event: 999))
    }

    func testLiveGGUFAppendReportsActualKVReuseWhenFixtureIsProvided() async throws {
        guard let modelPath = ProcessInfo.processInfo.environment["AUTOCOMP_TEST_GGUF_PATH"] else {
            throw XCTSkip("Set AUTOCOMP_TEST_GGUF_PATH for live prompt-reuse validation.")
        }
        let backend = LlamaCppRuntimeBackend()
        try await backend.loadModel(configuration: LocalLlamaConfiguration(
            modelPath: modelPath,
            modelName: "live-prompt-reuse",
            maxTokens: 2,
            maxRAMBytes: 512 * 1_024 * 1_024
        ))
        addTeardownBlock {
            await backend.shutdown()
        }

        _ = try await backend.generateCompletion(for: makeRequest(textBeforeCursor: "Once upon a time"))
        let cold = backend.cacheStats()
        _ = try await backend.generateCompletion(for: makeRequest(textBeforeCursor: "Once upon a time in"))
        let appended = backend.cacheStats()

        XCTAssertEqual(cold.lastResetReason, .coldStart)
        XCTAssertGreaterThan(appended.hits, 0)
        XCTAssertGreaterThan(appended.reuse.commonPrefixTokens, 0)
        XCTAssertGreaterThan(appended.reuse.reusedTokens, 0)
        XCTAssertLessThan(appended.reuse.prefillTokens, appended.reuse.promptTokens)
        XCTAssertNil(appended.lastResetReason)
        XCTAssertGreaterThanOrEqual(appended.reuse.tokenizationMilliseconds, 0)
        XCTAssertGreaterThanOrEqual(appended.reuse.prefillMilliseconds, 0)
        XCTAssertGreaterThanOrEqual(appended.reuse.decodeMilliseconds, 0)
    }

    func testLiveGGUFProfileAndMultiBranchScoringWhenFixtureIsProvided() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let modelPath = environment["AUTOCOMP_TEST_GGUF_PATH"],
              let profilePath = environment["AUTOCOMP_TEST_TOKEN_PROFILE_PATH"] else {
            throw XCTSkip("Set AUTOCOMP_TEST_GGUF_PATH and AUTOCOMP_TEST_TOKEN_PROFILE_PATH for live validation.")
        }
        let backend = LlamaCppRuntimeBackend()
        let runtime = LocalLlamaRuntimeCore(backend: backend)
        try await runtime.load(configuration: LocalLlamaConfiguration(
            modelPath: modelPath,
            modelName: "live-validation",
            maxTokens: 4,
            maxRAMBytes: 512 * 1_024 * 1_024
        ))
        let profile = try AutoCompTokenProfileCodec.load(from: URL(fileURLWithPath: profilePath))
        let actual = try await runtime.experimentalTokenProfile(modelFamily: profile.modelFamily)
        try AutoCompTokenProfileCodec.validate(
            profile,
            tokenizerDigest: actual.tokenizerDigest,
            vocabularySize: actual.vocabularySize
        )

        let result = try await AutoCompMultiBranchDecoder().decode(
            prompt: "Continue this sentence with a short phrase: Once upon a time",
            profile: profile,
            policy: AutoCompMultiBranchDecodePolicy(
                maximumTokens: 2,
                maximumDisplayWidth: 40,
                frontierWidth: 2,
                candidateCount: 2,
                candidatePoolSize: 64,
                minimumProbability: 0,
                relativeProbabilityCutoff: 0
            ),
            runtime: runtime
        )
        await runtime.shutdown()

        XCTAssertFalse(result.candidates.isEmpty)
        XCTAssertTrue(result.candidates.allSatisfy { !$0.text.isEmpty && $0.tokenIDs.count <= 2 })
        XCTAssertGreaterThan(result.metrics.scoredTokens, 0)
    }

    private func makeRequest(textBeforeCursor: String = "Can you ") -> CompletionRequest {
        let context = TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: textBeforeCursor
        )
        return CompletionRequestFactory().makeRequest(
            for: context,
            configuration: RemoteCompletionConfiguration(
                baseURL: "local://in-process",
                apiKey: "local",
                model: "local-llama"
            )
        )
    }
}
