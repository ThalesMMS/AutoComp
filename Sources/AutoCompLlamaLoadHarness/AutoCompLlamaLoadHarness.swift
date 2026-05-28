import AutoCompCore
import AutoCompLlamaRuntime
import Foundation

@main
struct AutoCompLlamaLoadHarness {
    static func main() async {
        do {
            let options = try parseOptions()
            if options.printStatus {
                printRuntimeStatus()
                return
            }

            guard let modelPath = options.modelPath else {
                throw HarnessError.missingModelPath
            }

            let backend = LlamaCppRuntimeBackend(loadVocabularyOnly: options.loadVocabularyOnly)
            let runtime = LocalLlamaRuntimeCore(backend: backend)
            let startedAt = Date()
            if let prompt = options.prompt {
                let provider = LocalLlamaCompletionProvider(
                    configuration: LocalLlamaConfiguration(
                        modelPath: modelPath,
                        maxTokens: options.maxTokens,
                        maxRAMBytes: options.maxRAMBytes
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
                try await runtime.load(configuration: LocalLlamaConfiguration(
                    modelPath: modelPath,
                    maxRAMBytes: options.maxRAMBytes
                ))
                let elapsed = Int(Date().timeIntervalSince(startedAt) * 1_000)
                print("Loaded and unloaded GGUF model in \(elapsed) ms: \(modelPath)")
            }
            await runtime.shutdown()
        } catch {
            fputs("AutoCompLlamaLoadHarness failed: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }

    private static func parseOptions() throws -> Options {
        var modelPath = configuredModelPath()
        var loadVocabularyOnly = false
        var prompt: String?
        var maxTokens = 16
        var maxRAMBytes: UInt64 = 6_442_450_944
        var repeatCount = 1
        var printStatus = false
        var remaining = Array(CommandLine.arguments.dropFirst())

        if let index = remaining.firstIndex(of: "--status") {
            printStatus = true
            remaining.remove(at: index)
        }

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

        if let index = remaining.firstIndex(of: "--max-ram-bytes") {
            let valueIndex = remaining.index(after: index)
            guard valueIndex < remaining.endIndex,
                  let value = UInt64(remaining[valueIndex]),
                  value > 0 else {
                throw HarnessError.invalidMaxRAMBytes
            }
            maxRAMBytes = value
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
            maxRAMBytes: maxRAMBytes,
            repeatCount: repeatCount,
            printStatus: printStatus
        )
    }

    private static func configuredModelPath() -> String? {
        let value = ProcessInfo.processInfo.environment["AUTOCOMP_LOCAL_MODEL_PATH"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value, !value.isEmpty else {
            return nil
        }
        return value
    }

    private static func printRuntimeStatus() {
        print("AutoComp local llama runtime: available")
        print("llama.cpp runtime status/version: linked")
        print("llama.cpp system info: \(LlamaCppRuntimeBackend.runtimeSystemInfo())")
    }

    private static func makeContext(textBeforeCursor: String) -> TextContext {
        TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 0),
            focusedElementID: "harness",
            textBeforeCursor: textBeforeCursor
        )
    }

    private struct Options {
        let modelPath: String?
        let loadVocabularyOnly: Bool
        let prompt: String?
        let maxTokens: Int
        let maxRAMBytes: UInt64
        let repeatCount: Int
        let printStatus: Bool
    }

    private enum HarnessError: LocalizedError {
        case missingModelPath
        case missingPrompt
        case invalidMaxTokens
        case invalidMaxRAMBytes
        case invalidRepeatCount

        var errorDescription: String? {
            switch self {
            case .missingModelPath:
                return "Pass a GGUF model path or set AUTOCOMP_LOCAL_MODEL_PATH. Use --status to check the linked runtime without a model."
            case .missingPrompt:
                return "--prompt requires a value."
            case .invalidMaxTokens:
                return "--max-tokens requires an integer value."
            case .invalidMaxRAMBytes:
                return "--max-ram-bytes requires a positive integer byte value."
            case .invalidRepeatCount:
                return "--repeat requires a positive integer value."
            }
        }
    }
}
