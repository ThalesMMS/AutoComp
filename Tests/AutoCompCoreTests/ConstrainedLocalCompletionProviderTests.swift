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

    func testFlaggedMidWordHealingRegeneratesFromSafeHeadAndRemovesVisibleStem() async throws {
        let backend = FakeConstrainedLocalRuntimeBackend(rawText: "dimensões adicionais, ões preservadas")
        let provider = makeProvider(
            backend: backend,
            expectedProfile: makeProfile(),
            midWordHealingEnabled: true
        )

        let suggestion = try await provider.complete(context: makeContext(
            textBeforeCursor: "Fígado de dimens",
            textAfterCursor: "ões preservadas"
        ))

        let request = await backend.lastRequest()
        XCTAssertEqual(suggestion.visibleText, "ões adicionais,")
        XCTAssertEqual(request?.truncatedTextBeforeCursor, "Fígado de ")
    }

    func testMultiBranchProfileFailureFallsBackToConventionalLocalGeneration() async throws {
        let backend = FakeConstrainedLocalRuntimeBackend(rawText: "fallback works")
        let sink = MultiBranchMetricsSink()
        let provider = ConstrainedLocalCompletionProvider(
            configuration: ConstrainedLocalCompletionConfiguration(
                localConfiguration: LocalLlamaConfiguration(modelPath: "/tmp/autocomp-test.gguf"),
                expectedTokenizerProfile: makeProfile(),
                multiBranchDecoderEnabled: true,
                tokenProfilePath: "/tmp/missing-\(UUID().uuidString).actkp"
            ),
            runtime: LocalLlamaRuntimeCore(backend: backend),
            multiBranchMetricsRecorder: { await sink.record($0) }
        )

        let suggestion = try await provider.complete(context: makeContext())
        let fallbackMetrics = await sink.last()

        XCTAssertEqual(suggestion.visibleText, "fallback works")
        XCTAssertEqual(fallbackMetrics?.fallbackReason, .profileMissing)
    }

    func testMultiBranchProviderPublishesDistinctOrderedCandidates() async throws {
        let records = [
            AutoCompTokenRecord(id: 0, bytes: Data("hello".utf8)),
            AutoCompTokenRecord(id: 1, bytes: Data("hi".utf8)),
            AutoCompTokenRecord(id: 2, bytes: Data(), flags: [.stop])
        ]
        let profile = AutoCompTokenProfile(
            modelFamily: "test",
            tokenizerDigest: AutoCompTokenProfileCodec.tokenizerDigest(records: records),
            records: records,
            stopTokenIDs: [2]
        )
        let profileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("autocomp-\(UUID().uuidString).actkp")
        try AutoCompTokenProfileCodec.encode(profile).write(to: profileURL)
        defer { try? FileManager.default.removeItem(at: profileURL) }
        let backend = FakeConstrainedLocalRuntimeBackend(
            rawText: "fallback",
            tokenProfile: profile,
            scores: [
                []: [.init(tokenID: 0, logProbability: log(0.6)), .init(tokenID: 1, logProbability: log(0.3))],
                [0]: [.init(tokenID: 2, logProbability: log(0.9))],
                [1]: [.init(tokenID: 2, logProbability: log(0.9))]
            ]
        )
        let provider = ConstrainedLocalCompletionProvider(
            configuration: ConstrainedLocalCompletionConfiguration(
                localConfiguration: LocalLlamaConfiguration(modelPath: "/tmp/autocomp-test.gguf"),
                expectedTokenizerProfile: makeProfile(),
                multiBranchDecoderEnabled: true,
                tokenProfilePath: profileURL.path,
                multiBranchPolicy: AutoCompMultiBranchDecodePolicy(
                    maximumTokens: 2,
                    frontierWidth: 2,
                    candidateCount: 2,
                    candidatePoolSize: 3,
                    minimumProbability: 0,
                    relativeProbabilityCutoff: 0
                )
            ),
            runtime: LocalLlamaRuntimeCore(backend: backend)
        )

        let suggestions = try await provider.complete(
            context: makeContext(textBeforeCursor: "Please "),
            privacySettings: PrivacySettings(),
            visualContext: nil,
            clipboardContext: nil,
            personalizationSamples: [],
            options: CompletionOptions(suggestionCount: 2)
        )

        XCTAssertEqual(suggestions.map(\.visibleText), ["hello", "hi"])
    }

    private func makeProvider(
        backend: FakeConstrainedLocalRuntimeBackend,
        expectedProfile: LocalLlamaTokenizerProfile?,
        midWordHealingEnabled: Bool = false
    ) -> ConstrainedLocalCompletionProvider {
        ConstrainedLocalCompletionProvider(
            configuration: ConstrainedLocalCompletionConfiguration(
                localConfiguration: LocalLlamaConfiguration(modelPath: "/tmp/autocomp-test.gguf"),
                expectedTokenizerProfile: expectedProfile,
                midWordHealingEnabled: midWordHealingEnabled
            ),
            runtime: LocalLlamaRuntimeCore(backend: backend)
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
    let tokenProfileValue: AutoCompTokenProfile?
    let scores: [[Int32]: [AutoCompScoredToken]]

    init(
        rawText: String,
        tokenizerProfile: LocalLlamaTokenizerProfile = LocalLlamaTokenizerProfile(
            tokenizerKind: "llama-vocab-type-2",
            vocabularySize: 32_000,
            specialTokenSignature: "bos:1|eos:2|eot:3|nl:13|fim_pre:100|fim_suf:101|fim_mid:102",
            supportsFillInMiddle: true
        ),
        tokenProfile: AutoCompTokenProfile? = nil,
        scores: [[Int32]: [AutoCompScoredToken]] = [:]
    ) {
        self.rawText = rawText
        self.tokenizerProfileValue = tokenizerProfile
        self.tokenProfileValue = tokenProfile
        self.scores = scores
    }

    func loadModel(configuration: LocalLlamaConfiguration) async throws {}

    func generateCompletion(for request: CompletionRequest) async throws -> String {
        storedRequest = request
        return CompletionStopSequenceTrimmer.trim(rawText, stopSequences: request.stopSequences)
    }

    func tokenizerProfile() async throws -> LocalLlamaTokenizerProfile {
        tokenizerProfileValue
    }

    func experimentalTokenProfile(modelFamily: String) async throws -> AutoCompTokenProfile {
        guard let tokenProfileValue else { throw LocalLlamaError.runtimeUnavailable }
        return tokenProfileValue
    }

    func topTokens(
        prompt: String,
        generatedTokenIDs: [Int32],
        allowedTokenIDs: [Int32]?,
        limit: Int
    ) async throws -> [AutoCompScoredToken] {
        let allowed = allowedTokenIDs.map(Set.init)
        return Array((scores[generatedTokenIDs] ?? [])
            .filter { allowed?.contains($0.tokenID) ?? true }
            .prefix(limit))
    }

    func shutdown() async {}

    func lastRequest() -> CompletionRequest? {
        storedRequest
    }
}

private actor MultiBranchMetricsSink {
    private var metrics: [AutoCompMultiBranchMetrics] = []
    func record(_ value: AutoCompMultiBranchMetrics) { metrics.append(value) }
    func last() -> AutoCompMultiBranchMetrics? { metrics.last }
}
#endif
