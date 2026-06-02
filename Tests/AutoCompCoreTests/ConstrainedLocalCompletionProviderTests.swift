#if AUTOCOMP_CONSTRAINED_LOCAL_COMPLETION
import AutoCompCore
import XCTest

final class ConstrainedLocalCompletionProviderTests: XCTestCase {
    func testTokenizerProfileMismatchIsRejected() async throws {
        let expected = makeProfile(vocabularySize: 64_000)
        let backend = FakeConstrainedLocalRuntimeBackend(
            rawText: "Completion:\n works",
            tokenizerProfile: makeProfile(vocabularySize: 32_000)
        )
        let provider = makeProvider(backend: backend, expectedProfile: expected)

        do {
            _ = try await provider.complete(context: makeContext())
            XCTFail("Expected tokenizer profile mismatch")
        } catch let error as ConstrainedLocalCompletionError {
            guard case .tokenizerProfileMismatch(let expectedProfile, let actualProfile) = error else {
                return XCTFail("Unexpected constrained error: \(error)")
            }
            XCTAssertEqual(expectedProfile.vocabularySize, 64_000)
            XCTAssertEqual(actualProfile.vocabularySize, 32_000)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testFillInMiddleRequestWhenSuffixExists() async throws {
        let backend = FakeConstrainedLocalRuntimeBackend(
            rawText: "adiada para sexta-feira porque o prazo mudou."
        )
        let provider = makeProvider(backend: backend, expectedProfile: makeProfile())

        let suggestion = try await provider.complete(
            context: makeContext(
                textBeforeCursor: "A reuniao foi ",
                textAfterCursor: " porque o prazo mudou."
            )
        )

        XCTAssertEqual(suggestion.visibleText, "adiada para sexta-feira")
        XCTAssertGreaterThanOrEqual(suggestion.latencyMs, 0)
        let request = await backend.lastRequest()
        XCTAssertEqual(request?.mode, .fillInMiddle)
        XCTAssertEqual(request?.fimSuffixInjected, true)
        XCTAssertEqual(request?.stopSequences, CompletionStopSequences.conservativeDefault.fillInMiddle)
    }

    func testContinuationRequestWhenNoSuffixExists() async throws {
        let backend = FakeConstrainedLocalRuntimeBackend(rawText: "review this today")
        let provider = makeProvider(backend: backend, expectedProfile: makeProfile())

        let suggestion = try await provider.complete(context: makeContext(textBeforeCursor: "Please "))

        XCTAssertEqual(suggestion.visibleText, "review this today")
        let request = await backend.lastRequest()
        XCTAssertEqual(request?.mode, .continuation)
        XCTAssertEqual(request?.fimSuffixInjected, false)
        XCTAssertEqual(request?.stopSequences, CompletionStopSequences.conservativeDefault.continuation)
    }

    func testEmptyCandidateThrowsNoSuggestion() async throws {
        let provider = makeProvider(
            backend: FakeConstrainedLocalRuntimeBackend(rawText: "Completion:\n\n"),
            expectedProfile: makeProfile()
        )

        do {
            _ = try await provider.complete(context: makeContext())
            XCTFail("Expected empty candidate")
        } catch let error as ConstrainedLocalCompletionError {
            XCTAssertEqual(error, .emptyCandidate)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCandidateDuplicatingSuffixIsSuppressed() async throws {
        let provider = makeProvider(
            backend: FakeConstrainedLocalRuntimeBackend(rawText: " because the date moved."),
            expectedProfile: makeProfile()
        )

        do {
            _ = try await provider.complete(
                context: makeContext(
                    textBeforeCursor: "The meeting moved",
                    textAfterCursor: " because the date moved."
                )
            )
            XCTFail("Expected duplicate suffix suppression")
        } catch let error as ConstrainedLocalCompletionError {
            XCTAssertEqual(error, .emptyCandidate)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCandidateOverlappingSuffixIsTruncated() async throws {
        let backend = FakeConstrainedLocalRuntimeBackend(rawText: "Friday because")
        let provider = makeProvider(backend: backend, expectedProfile: makeProfile())

        let suggestion = try await provider.complete(
            context: makeContext(
                textBeforeCursor: "The meeting moved to ",
                textAfterCursor: " because the date changed."
            )
        )

        XCTAssertEqual(suggestion.visibleText, "Friday")
    }

    private func makeProvider(
        backend: FakeConstrainedLocalRuntimeBackend,
        expectedProfile: LocalLlamaTokenizerProfile?
    ) -> ConstrainedLocalCompletionProvider {
        ConstrainedLocalCompletionProvider(
            configuration: ConstrainedLocalCompletionConfiguration(
                localConfiguration: LocalLlamaConfiguration(modelPath: "/tmp/autocomp-test.gguf"),
                expectedTokenizerProfile: expectedProfile
            ),
            runtime: LocalLlamaRuntimeCore(backend: backend)
        )
    }

    private func makeContext(
        textBeforeCursor: String = "Can you ",
        textAfterCursor: String? = nil
    ) -> TextContext {
        TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: textBeforeCursor,
            textAfterCursor: textAfterCursor
        )
    }

    private func makeProfile(
        vocabularySize: Int = 32_000,
        supportsFillInMiddle: Bool = true
    ) -> LocalLlamaTokenizerProfile {
        LocalLlamaTokenizerProfile(
            tokenizerKind: "llama-vocab-type-2",
            vocabularySize: vocabularySize,
            specialTokenSignature: "bos:1|eos:2|eot:3|nl:13|fim_pre:100|fim_suf:101|fim_mid:102",
            supportsFillInMiddle: supportsFillInMiddle
        )
    }
}

private actor FakeConstrainedLocalRuntimeBackend: LocalLlamaRuntimeBackend {
    let rawText: String
    let tokenizerProfileValue: LocalLlamaTokenizerProfile
    private var storedRequest: CompletionRequest?

    init(
        rawText: String,
        tokenizerProfile: LocalLlamaTokenizerProfile = LocalLlamaTokenizerProfile(
            tokenizerKind: "llama-vocab-type-2",
            vocabularySize: 32_000,
            specialTokenSignature: "bos:1|eos:2|eot:3|nl:13|fim_pre:100|fim_suf:101|fim_mid:102",
            supportsFillInMiddle: true
        )
    ) {
        self.rawText = rawText
        self.tokenizerProfileValue = tokenizerProfile
    }

    func loadModel(configuration: LocalLlamaConfiguration) async throws {}

    func generateCompletion(for request: CompletionRequest) async throws -> String {
        storedRequest = request
        return CompletionStopSequenceTrimmer.trim(rawText, stopSequences: request.stopSequences)
    }

    func tokenizerProfile() async throws -> LocalLlamaTokenizerProfile {
        tokenizerProfileValue
    }

    func shutdown() async {}

    func lastRequest() -> CompletionRequest? {
        storedRequest
    }
}
#endif
