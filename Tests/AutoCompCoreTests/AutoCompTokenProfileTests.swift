import AutoCompCore
import Foundation
import XCTest

final class AutoCompTokenProfileTests: XCTestCase {
    func testASCIIWhitespacePrecedesControlClassification() {
        for byte in UInt8(9)...UInt8(13) {
            XCTAssertEqual(AutoCompTokenByteClass(byte: byte), .asciiWhitespace)
        }
        XCTAssertEqual(AutoCompTokenByteClass(byte: 0), .asciiControl)
        XCTAssertEqual(AutoCompTokenByteClass(byte: 31), .asciiControl)
        XCTAssertEqual(AutoCompTokenByteClass(byte: 127), .asciiControl)
        XCTAssertEqual(AutoCompTokenByteClass(byte: 32), .asciiWhitespace)
    }

    func testBinaryProfileRoundTripsDeterministically() throws {
        let profile = makeProfile()

        let first = try AutoCompTokenProfileCodec.encode(profile)
        let decoded = try AutoCompTokenProfileCodec.decode(first)
        let second = try AutoCompTokenProfileCodec.encode(decoded)

        XCTAssertEqual(decoded, profile)
        XCTAssertEqual(first, second)
        XCTAssertEqual(Array(first.prefix(7)), Array("ACTKP01".utf8))
    }

    func testBinaryProfileRejectsCorruptionAndTruncation() throws {
        let encoded = try AutoCompTokenProfileCodec.encode(makeProfile())
        var corrupt = encoded
        corrupt[corrupt.index(corrupt.startIndex, offsetBy: 24)] ^= 0x01

        XCTAssertThrowsError(try AutoCompTokenProfileCodec.decode(corrupt)) { error in
            XCTAssertEqual(error as? AutoCompTokenProfileError, .checksumMismatch)
        }
        XCTAssertThrowsError(try AutoCompTokenProfileCodec.decode(encoded.dropLast(7)))
    }

    func testDecoderRejectsVocabularyReservationBeyondRemainingBytes() throws {
        var encoded = try AutoCompTokenProfileCodec.encode(makeProfile())
        var oversizedVocabulary = UInt32.max.littleEndian
        withUnsafeBytes(of: &oversizedVocabulary) { bytes in
            encoded.replaceSubrange(22..<26, with: bytes)
        }
        var checksum = crc32(Data(encoded.dropLast(4))).littleEndian
        withUnsafeBytes(of: &checksum) { bytes in
            encoded.replaceSubrange((encoded.count - 4)..<encoded.count, with: bytes)
        }

        XCTAssertThrowsError(try AutoCompTokenProfileCodec.decode(encoded)) { error in
            XCTAssertEqual(error as? AutoCompTokenProfileError, .truncated)
        }
    }

    func testProfileValidationRejectsDigestAndVocabularyMismatch() throws {
        let profile = makeProfile()

        XCTAssertThrowsError(try AutoCompTokenProfileCodec.validate(
            profile,
            tokenizerDigest: Data([0xFF]),
            vocabularySize: profile.vocabularySize
        )) { error in
            XCTAssertEqual(error as? AutoCompTokenProfileError, .tokenizerDigestMismatch)
        }
        XCTAssertThrowsError(try AutoCompTokenProfileCodec.validate(
            profile,
            tokenizerDigest: profile.tokenizerDigest,
            vocabularySize: profile.vocabularySize + 1
        ))
    }

    func testPrefixIndexFindsUTF8TokensWithoutConflatingPrefixes() {
        let records = [
            AutoCompTokenRecord(id: 0, bytes: Data("ca".utf8)),
            AutoCompTokenRecord(id: 1, bytes: Data("café".utf8)),
            AutoCompTokenRecord(id: 2, bytes: Data("casa".utf8)),
            AutoCompTokenRecord(id: 3, bytes: Data("chá".utf8))
        ]
        let index = AutoCompTokenPrefixIndex(records: records)

        XCTAssertEqual(index.tokenIDs(startingWith: Data("caf".utf8)), [1])
        XCTAssertEqual(index.tokenIDs(startingWith: Data("ca".utf8)), [0, 1, 2])
        XCTAssertEqual(index.tokenIDs(startingWith: Data("ç".utf8)), [])
    }

    func testDecoderReturnsDistinctOrderedBranchesAndBlocksControlTokens() async throws {
        let records = [
            AutoCompTokenRecord(id: 0, bytes: Data("alpha".utf8)),
            AutoCompTokenRecord(id: 1, bytes: Data("beta".utf8)),
            AutoCompTokenRecord(id: 2, bytes: Data(), flags: [.stop, .endOfGeneration]),
            AutoCompTokenRecord(id: 3, bytes: Data("hidden".utf8), flags: [.control])
        ]
        let profile = profile(records: records, stopTokenIDs: [2])
        let runtime = ScriptedTokenRuntime(scores: [
            []: [
                AutoCompScoredToken(tokenID: 3, logProbability: log(0.9)),
                AutoCompScoredToken(tokenID: 0, logProbability: log(0.6)),
                AutoCompScoredToken(tokenID: 1, logProbability: log(0.3))
            ],
            [0]: [AutoCompScoredToken(tokenID: 2, logProbability: log(0.9))],
            [1]: [AutoCompScoredToken(tokenID: 2, logProbability: log(0.9))]
        ])

        let result = try await AutoCompMultiBranchDecoder().decode(
            prompt: "continue",
            profile: profile,
            policy: AutoCompMultiBranchDecodePolicy(
                maximumTokens: 2,
                frontierWidth: 3,
                candidateCount: 3,
                candidatePoolSize: 4,
                relativeProbabilityCutoff: 0
            ),
            runtime: runtime
        )

        XCTAssertEqual(result.candidates.map(\.text), ["alpha", "beta"])
        XCTAssertEqual(result.candidates.map(\.tokenIDs), [[0, 2], [1, 2]])
        XCTAssertGreaterThan(result.metrics.suppressedTokens, 0)
    }

    func testDecoderTraversesRequiredPrefixDuringGeneration() async throws {
        let records = [
            AutoCompTokenRecord(id: 0, bytes: Data("h".utf8)),
            AutoCompTokenRecord(id: 1, bytes: Data("he".utf8)),
            AutoCompTokenRecord(id: 2, bytes: Data("llo".utf8)),
            AutoCompTokenRecord(id: 3, bytes: Data("ello".utf8)),
            AutoCompTokenRecord(id: 4, bytes: Data(" world".utf8)),
            AutoCompTokenRecord(id: 5, bytes: Data(), flags: [.stop])
        ]
        let runtime = ScriptedTokenRuntime(scores: [
            []: [.init(tokenID: 4, logProbability: log(0.95)), .init(tokenID: 1, logProbability: log(0.5))],
            [1]: [.init(tokenID: 2, logProbability: log(0.8))],
            [1, 2]: [.init(tokenID: 4, logProbability: log(0.7))],
            [1, 2, 4]: [.init(tokenID: 5, logProbability: log(0.9))]
        ])

        let result = try await AutoCompMultiBranchDecoder().decode(
            prompt: "finish",
            requiredPrefix: "hel",
            profile: profile(records: records, stopTokenIDs: [5]),
            policy: AutoCompMultiBranchDecodePolicy(
                maximumTokens: 4,
                frontierWidth: 2,
                candidateCount: 1,
                candidatePoolSize: 6,
                relativeProbabilityCutoff: 0
            ),
            runtime: runtime
        )

        XCTAssertEqual(result.candidates.first?.text, "hello world")
        let calls = await runtime.recordedAllowedTokenIDs()
        XCTAssertEqual(calls.first, [0, 1])
        XCTAssertEqual(calls.dropFirst().first, [2])
    }

    func testStopSequenceTruncationKeepsBranchFieldsConsistent() async throws {
        let records = [
            AutoCompTokenRecord(id: 0, bytes: Data("hello".utf8)),
            AutoCompTokenRecord(id: 1, bytes: Data("<STOP>".utf8))
        ]
        let firstLogProbability = Float(log(0.6))
        let runtime = ScriptedTokenRuntime(scores: [
            []: [.init(tokenID: 0, logProbability: firstLogProbability)],
            [0]: [.init(tokenID: 1, logProbability: Float(log(0.5)))]
        ])

        let result = try await AutoCompMultiBranchDecoder().decode(
            prompt: "continue",
            profile: profile(records: records),
            policy: AutoCompMultiBranchDecodePolicy(
                maximumTokens: 2,
                maximumDisplayWidth: 20,
                frontierWidth: 1,
                candidateCount: 1,
                candidatePoolSize: 2,
                relativeProbabilityCutoff: 0,
                stopSequences: ["<STOP>"]
            ),
            runtime: runtime
        )

        let candidate = try XCTUnwrap(result.candidates.first)
        XCTAssertEqual(candidate.text, "hello")
        XCTAssertEqual(candidate.tokenIDs, [0])
        XCTAssertEqual(candidate.logProbability, firstLogProbability, accuracy: 0.000_001)
    }

    func testDecoderCancellationDoesNotCallRuntime() async {
        let runtime = ScriptedTokenRuntime(scores: [:])
        let profile = makeProfile()
        let task = Task {
            try await AutoCompMultiBranchDecoder().decode(
                prompt: "cancel",
                profile: profile,
                policy: AutoCompMultiBranchDecodePolicy(),
                runtime: runtime
            )
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            let callCount = await runtime.callCount()
            XCTAssertEqual(callCount, 0)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func makeProfile() -> AutoCompTokenProfile {
        let records = [
            AutoCompTokenRecord(id: 0, bytes: Data(" hello".utf8), flags: [.printable]),
            AutoCompTokenRecord(id: 1, bytes: Data("\n".utf8), flags: [.whitespace]),
            AutoCompTokenRecord(id: 2, bytes: Data(), flags: [.special, .stop, .endOfGeneration])
        ]
        return profile(records: records, specialTokenIDs: [2], stopTokenIDs: [2])
    }

    private func profile(
        records: [AutoCompTokenRecord],
        specialTokenIDs: Set<Int32> = [],
        stopTokenIDs: Set<Int32> = []
    ) -> AutoCompTokenProfile {
        AutoCompTokenProfile(
            modelFamily: "autocomp-test",
            tokenizerDigest: AutoCompTokenProfileCodec.tokenizerDigest(records: records),
            records: records,
            specialTokenIDs: specialTokenIDs,
            stopTokenIDs: stopTokenIDs
        )
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc = UInt32.max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ (0xEDB8_8320 & (0 &- (crc & 1)))
            }
        }
        return ~crc
    }
}

private actor ScriptedTokenRuntime: AutoCompTokenScoringRuntime {
    private let scores: [[Int32]: [AutoCompScoredToken]]
    private var allowedCalls: [[Int32]?] = []

    init(scores: [[Int32]: [AutoCompScoredToken]]) {
        self.scores = scores
    }

    func topTokens(
        prompt: String,
        generatedTokenIDs: [Int32],
        allowedTokenIDs: [Int32]?,
        limit: Int
    ) async throws -> [AutoCompScoredToken] {
        allowedCalls.append(allowedTokenIDs)
        let allowed = allowedTokenIDs.map(Set.init)
        return Array((scores[generatedTokenIDs] ?? [])
            .filter { allowed?.contains($0.tokenID) ?? true }
            .sorted {
                $0.logProbability == $1.logProbability
                    ? $0.tokenID < $1.tokenID
                    : $0.logProbability > $1.logProbability
            }
            .prefix(limit))
    }

    func recordedAllowedTokenIDs() -> [[Int32]?] { allowedCalls }
    func callCount() -> Int { allowedCalls.count }
}
