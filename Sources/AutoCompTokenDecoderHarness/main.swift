import AutoCompCore
import AutoCompLlamaRuntime
import Foundation

@main
enum AutoCompTokenDecoderHarness {
    static func main() async {
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            guard arguments.count == 3 else { throw HarnessError.usage }
            let modelPath = arguments[0]
            let profileURL = URL(fileURLWithPath: arguments[1])
            let prompt = arguments[2]
            let runtime = LocalLlamaRuntimeCore(backend: LlamaCppRuntimeBackend())
            let startedAt = ContinuousClock.now
            try await runtime.load(configuration: LocalLlamaConfiguration(
                modelPath: modelPath,
                modelName: "token-decoder-harness",
                maxTokens: 8
            ))
            let loadedAt = ContinuousClock.now
            let profile = try AutoCompTokenProfileCodec.load(from: profileURL)
            let profileLoadedAt = ContinuousClock.now
            let actual = try await runtime.experimentalTokenProfile(modelFamily: profile.modelFamily)
            try AutoCompTokenProfileCodec.validate(
                profile,
                tokenizerDigest: actual.tokenizerDigest,
                vocabularySize: actual.vocabularySize
            )
            let validatedAt = ContinuousClock.now
            let result = try await AutoCompMultiBranchDecoder().decode(
                prompt: prompt,
                profile: profile,
                policy: AutoCompMultiBranchDecodePolicy(
                    maximumTokens: 8,
                    frontierWidth: 4,
                    candidateCount: 3,
                    candidatePoolSize: 64
                ),
                runtime: runtime
            )
            let completedAt = ContinuousClock.now
            await runtime.shutdown()
            let profileBytes = ((try? FileManager.default.attributesOfItem(atPath: profileURL.path))?[.size] as? NSNumber)?.intValue ?? 0
            let payload: [String: Any] = [
                "schema": 1,
                "model_load_ms": startedAt.duration(to: loadedAt).milliseconds,
                "profile_load_ms": loadedAt.duration(to: profileLoadedAt).milliseconds,
                "profile_validation_ms": profileLoadedAt.duration(to: validatedAt).milliseconds,
                "decode_ms": validatedAt.duration(to: completedAt).milliseconds,
                "profile_bytes": profileBytes,
                "vocabulary_size": profile.vocabularySize,
                "branches_expanded": result.metrics.branchesExpanded,
                "branches_pruned": result.metrics.branchesPruned,
                "maximum_depth": result.metrics.maximumDepth,
                "scored_tokens": result.metrics.scoredTokens,
                "suppressed_tokens": result.metrics.suppressedTokens,
                "candidate_count": result.candidates.count,
                "cancellation_count": result.metrics.cancellationCount,
                "wrong_show_count": result.metrics.wrongShowCount,
                "candidate_token_counts": result.candidates.map { $0.tokenIDs.count },
                "candidate_log_probabilities": result.candidates.map { $0.logProbability }
            ]
            let encoded = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])
            print(String(decoding: encoded, as: UTF8.self))
        } catch {
            FileHandle.standardError.write(Data("error: \(error.localizedDescription)\n".utf8))
            exit(2)
        }
    }
}

private enum HarnessError: LocalizedError {
    case usage

    var errorDescription: String? {
        "Usage: AutoCompTokenDecoderHarness <model.gguf> <profile.actkp> <prompt>"
    }
}
