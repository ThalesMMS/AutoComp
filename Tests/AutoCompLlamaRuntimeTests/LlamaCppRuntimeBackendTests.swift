import AutoCompCore
@testable import AutoCompLlamaRuntime
import XCTest

final class LlamaCppRuntimeBackendTests: XCTestCase {
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

    private func makeRequest() -> CompletionRequest {
        let context = TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: "Can you "
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
