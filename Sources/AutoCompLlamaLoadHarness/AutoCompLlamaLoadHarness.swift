import AutoCompCore
import AutoCompLlamaRuntime
import Foundation

@main
struct AutoCompLlamaLoadHarness {
    private static let defaultModelPath = "/Users/thales/Library/Application Support/app.cotypist.Cotypist/Models/gemma-4-E2B-i1-Q4_K_M.gguf"

    static func main() async {
        do {
            let options = try parseOptions()
            let backend = LlamaCppRuntimeBackend(loadVocabularyOnly: options.loadVocabularyOnly)
            let runtime = LocalLlamaRuntimeCore(backend: backend)
            let startedAt = Date()
            if let prompt = options.prompt {
                let provider = LocalLlamaCompletionProvider(
                    configuration: LocalLlamaConfiguration(
                        modelPath: options.modelPath,
                        maxTokens: options.maxTokens
                    ),
                    runtime: runtime
                )
                for attempt in 1...options.repeatCount {
                    let attemptStartedAt = Date()
                    let suggestion = try await provider.complete(context: makeContext(textBeforeCursor: prompt))
                    let elapsed = Int(Date().timeIntervalSince(attemptStartedAt) * 1_000)
                    print("Generated local completion \(attempt)/\(options.repeatCount) in \(elapsed) ms: \(suggestion.visibleText)")
                }
                let elapsed = Int(Date().timeIntervalSince(startedAt) * 1_000)
                let stats = backend.cacheStats()
                print(
                    "Prompt cache after \(elapsed) ms: hits=\(stats.hits) misses=\(stats.misses) resets=\(stats.resets) retainedPromptTokens=\(stats.retainedPromptTokens) contextTokens=\(stats.contextTokens)"
                )
            } else {
                try await runtime.load(configuration: LocalLlamaConfiguration(modelPath: options.modelPath))
                let elapsed = Int(Date().timeIntervalSince(startedAt) * 1_000)
                print("Loaded and unloaded GGUF model in \(elapsed) ms: \(options.modelPath)")
            }
            await runtime.shutdown()
        } catch {
            fputs("AutoCompLlamaLoadHarness failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func parseOptions() throws -> Options {
        var modelPath = defaultModelPath
        var loadVocabularyOnly = false
        var prompt: String?
        var maxTokens = 16
        var repeatCount = 1
        var remaining = Array(CommandLine.arguments.dropFirst())

        if let index = remaining.firstIndex(of: "--vocab-only") {
            loadVocabularyOnly = true
            remaining.remove(at: index)
        }

        if let index = remaining.firstIndex(of: "--prompt") {
            let valueIndex = remaining.index(after: index)
            guard valueIndex < remaining.endIndex else {
                throw HarnessError.missingPrompt
            }
            prompt = remaining[valueIndex]
            remaining.remove(at: valueIndex)
            remaining.remove(at: index)
        }

        if let index = remaining.firstIndex(of: "--max-tokens") {
            let valueIndex = remaining.index(after: index)
            guard valueIndex < remaining.endIndex, let value = Int(remaining[valueIndex]) else {
                throw HarnessError.invalidMaxTokens
            }
            maxTokens = value
            remaining.remove(at: valueIndex)
            remaining.remove(at: index)
        }

        if let index = remaining.firstIndex(of: "--repeat") {
            let valueIndex = remaining.index(after: index)
            guard valueIndex < remaining.endIndex, let value = Int(remaining[valueIndex]), value > 0 else {
                throw HarnessError.invalidRepeatCount
            }
            repeatCount = value
            remaining.remove(at: valueIndex)
            remaining.remove(at: index)
        }

        if let providedPath = remaining.first {
            modelPath = providedPath
        }

        return Options(
            modelPath: modelPath,
            loadVocabularyOnly: loadVocabularyOnly,
            prompt: prompt,
            maxTokens: maxTokens,
            repeatCount: repeatCount
        )
    }

    private static func makeContext(textBeforeCursor: String) -> TextContext {
        TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 0),
            focusedElementID: "harness",
            textBeforeCursor: textBeforeCursor
        )
    }

    private struct Options {
        let modelPath: String
        let loadVocabularyOnly: Bool
        let prompt: String?
        let maxTokens: Int
        let repeatCount: Int
    }

    private enum HarnessError: LocalizedError {
        case missingPrompt
        case invalidMaxTokens
        case invalidRepeatCount

        var errorDescription: String? {
            switch self {
            case .missingPrompt:
                return "--prompt requires a value."
            case .invalidMaxTokens:
                return "--max-tokens requires an integer value."
            case .invalidRepeatCount:
                return "--repeat requires a positive integer value."
            }
        }
    }
}
