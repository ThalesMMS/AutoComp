import AutoCompCore
@testable import AutoCompApp
import XCTest

final class CompletionPlaygroundServiceTests: XCTestCase {
    func testPreviewUsesContinuationWithoutSuffix() {
        let service = CompletionPlaygroundService()

        let preview = service.preview(
            prefix: "Please write ",
            suffix: "",
            settings: CompletionBackendSettings(remoteModel: "test-model")
        )

        XCTAssertEqual(preview.request.mode, .continuation)
        XCTAssertEqual(preview.modeTitle, "Continuation")
        XCTAssertEqual(preview.request.truncatedTextBeforeCursor, "Please write ")
        XCTAssertNil(preview.request.truncatedTextAfterCursor)
        XCTAssertEqual(preview.request.model, "test-model")
        XCTAssertEqual(preview.requestDestinationTitle, "Remote: test-model at http://100.98.1.45:8000")
        XCTAssertTrue(preview.dataLeavesDeviceTitle.contains("sent to http://100.98.1.45:8000"))
        XCTAssertEqual(preview.remoteFallbackTitle, "Not applicable because the remote backend is selected.")
    }

    func testPreviewUsesFillInMiddleWithSuffix() {
        let service = CompletionPlaygroundService()

        let preview = service.preview(
            prefix: "Please ",
            suffix: " before Friday.",
            settings: CompletionBackendSettings(remoteModel: "test-model")
        )

        XCTAssertEqual(preview.request.mode, .fillInMiddle)
        XCTAssertEqual(preview.modeTitle, "Fill in middle")
        XCTAssertEqual(preview.request.truncatedTextBeforeCursor, "Please ")
        XCTAssertEqual(preview.request.truncatedTextAfterCursor, " before Friday.")
        XCTAssertTrue(preview.request.fimSuffixInjected)
    }

    func testPreviewLabelsLocalFirstDestinationAndRemoteFallbackPolicy() {
        let service = CompletionPlaygroundService()
        let settings = CompletionBackendSettings(
            engineKind: .localLlama,
            remoteBaseURL: "http://127.0.0.1:8000",
            localModelPath: "/tmp/autocomp.gguf",
            fallbackToRemoteOnLocalFailure: true
        )

        let preview = service.preview(prefix: "Please ", suffix: "", settings: settings)

        XCTAssertEqual(preview.requestDestinationTitle, "Local in-process: autocomp.gguf")
        XCTAssertEqual(
            preview.dataLeavesDeviceTitle,
            "Local first; text may be sent to http://127.0.0.1:8000 after a local failure."
        )
        XCTAssertEqual(preview.remoteFallbackTitle, "Enabled after local failure")
    }

    func testPromptPreviewShowsCountsWithoutSensitiveContentWhenDebugOff() throws {
        let preview = CompletionPlaygroundService().preview(
            prefix: "SECRET_PREFIX_123",
            suffix: "SECRET_SUFFIX_123",
            settings: CompletionBackendSettings(remoteModel: "test-model")
        )

        let promptPreview = try XCTUnwrap(preview.promptPreview(options: .normal))

        XCTAssertTrue(promptPreview.contains("Sensitive prompt content hidden until local debug opt-in is enabled."))
        XCTAssertTrue(promptPreview.contains("Mode: Fill in middle"))
        XCTAssertTrue(promptPreview.contains("Prompt size: chars="))
        XCTAssertTrue(promptPreview.contains("Text before cursor: chars=17"))
        XCTAssertTrue(promptPreview.contains("Text after cursor: chars=17"))
        XCTAssertTrue(promptPreview.contains("Capture sources: count=1"))
        XCTAssertTrue(promptPreview.contains("Echo candidates: count="))
        XCTAssertFalse(promptPreview.contains("SECRET_PREFIX_123"))
        XCTAssertFalse(promptPreview.contains("SECRET_SUFFIX_123"))
    }

    func testFillInMiddlePromptPreviewShowsOnlyRedactionMetadataWhenDebugOff() throws {
        let preview = CompletionPlaygroundService().preview(
            prefix: "PRIVATE_FIM_PREFIX",
            suffix: "PRIVATE_FIM_SUFFIX",
            settings: CompletionBackendSettings(remoteModel: "test-model")
        )

        let promptPreview = try XCTUnwrap(preview.promptPreview(options: .normal))

        XCTAssertEqual(preview.request.mode, .fillInMiddle)
        XCTAssertTrue(promptPreview.contains("Sensitive prompt content hidden until local debug opt-in is enabled."))
        XCTAssertTrue(promptPreview.contains("Mode: Fill in middle"))
        XCTAssertTrue(promptPreview.contains("Prompt size: chars="))
        XCTAssertTrue(promptPreview.contains("Text before cursor: chars=18"))
        XCTAssertTrue(promptPreview.contains("Text after cursor: chars=18"))
        XCTAssertTrue(promptPreview.contains("Echo candidates: count="))
        XCTAssertFalse(promptPreview.contains("Text before cursor (prefix):"))
        XCTAssertFalse(promptPreview.contains("Text after cursor (suffix):"))
        XCTAssertFalse(promptPreview.contains("<|fim_suffix|>"))
        XCTAssertFalse(promptPreview.contains("PRIVATE_FIM_PREFIX"))
        XCTAssertFalse(promptPreview.contains("PRIVATE_FIM_SUFFIX"))
    }

    func testPromptPreviewShowsFullPromptWhenSensitiveDebugOptIn() throws {
        let preview = CompletionPlaygroundService().preview(
            prefix: "SECRET_PREFIX_123",
            suffix: "SECRET_SUFFIX_123",
            settings: CompletionBackendSettings(remoteModel: "test-model")
        )

        let promptPreview = try XCTUnwrap(preview.promptPreview(
            options: AutoCompDebugOptions(localDebugOptIn: true)
        ))

        XCTAssertTrue(promptPreview.contains("Text before cursor (prefix):\nSECRET_PREFIX_123"))
        XCTAssertTrue(promptPreview.contains("Text after cursor (suffix):\nSECRET_SUFFIX_123"))
    }

    func testCompletionReturnsPromptRawNormalizedAndLatency() async throws {
        let service = CompletionPlaygroundService()
        let provider = RecordingPlaygroundCompletionProvider()

        let result = try await service.complete(
            prefix: "Please ",
            suffix: " before Friday.",
            settings: CompletionBackendSettings(remoteModel: "test-model"),
            provider: provider
        )

        XCTAssertEqual(result.preview.request.mode, .fillInMiddle)
        XCTAssertEqual(result.rawOutput, "Completion:\n finish this before Friday.")
        XCTAssertEqual(result.normalizedOutput, "finish this")
        XCTAssertEqual(result.latencyMs, 17)
        let recordedContext = await provider.recordedContext()
        XCTAssertEqual(recordedContext?.textBeforeCursor, "Please ")
        XCTAssertEqual(recordedContext?.textAfterCursor, " before Friday.")
    }
}

private actor RecordingPlaygroundCompletionProvider: CompletionProvider {
    private var context: TextContext?

    func recordedContext() -> TextContext? {
        context
    }

    func complete(context: TextContext) async throws -> Suggestion {
        self.context = context
        let rawText = "Completion:\n finish this\(context.textAfterCursor ?? "")"
        let normalizedText = SuggestionTextNormalizer.normalize(
            rawText: rawText,
            precedingText: context.textBeforeCursor,
            trailingText: context.textAfterCursor
        )
        return Suggestion(
            baseContextID: context.id,
            visibleText: normalizedText,
            rawText: rawText,
            latencyMs: 17
        )
    }
}
