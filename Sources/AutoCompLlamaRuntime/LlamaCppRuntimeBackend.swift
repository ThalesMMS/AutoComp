import AutoCompCore
internal import CLlamaBridge
import Foundation

public final class LlamaCppRuntimeBackend: LocalLlamaRuntimeBackend, @unchecked Sendable {
    private let loadVocabularyOnly: Bool
    private let backendLifecycle: LlamaBackendGlobalLifecycle
    private let lock = NSLock()
    private var loadedModel: OpaquePointer?
    private var backendRetained = false

    public static func runtimeSystemInfo() -> String {
        guard let info = autocomp_llama_system_info() else {
            return "unavailable"
        }
        let value = String(cString: info).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return "not reported by linked llama.cpp"
        }
        return value
    }

    public init(loadVocabularyOnly: Bool = false) {
        self.loadVocabularyOnly = loadVocabularyOnly
        self.backendLifecycle = .shared
    }

    init(loadVocabularyOnly: Bool, backendLifecycle: LlamaBackendGlobalLifecycle) {
        self.loadVocabularyOnly = loadVocabularyOnly
        self.backendLifecycle = backendLifecycle
    }

    deinit {
        lock.withLock {
            unloadLocked()
            releaseBackendLocked()
        }
    }

    public func loadModel(configuration: LocalLlamaConfiguration) async throws {
        guard FileManager.default.fileExists(atPath: configuration.modelPath) else {
            throw LocalLlamaError.modelNotFound(configuration.modelPath)
        }
        try enforceRAMLimit(configuration: configuration)

        try lock.withLock {
            retainBackendLocked()

            unloadLocked()
            var error = AutoCompLlamaError()
            let model = configuration.modelPath.withCString { path in
                autocomp_llama_model_load(path, loadVocabularyOnly, &error)
            }
            guard let model else {
                releaseBackendLocked()
                throw Self.loadError(
                    message: String(cString: autocomp_llama_error_message(&error)),
                    code: error.code
                )
            }
            loadedModel = model
        }
    }

    public func generateCompletion(for request: CompletionRequest) async throws -> String {
        try Task.checkCancellation()
        return try await Task.detached(priority: .userInitiated) { [self] in
            try Task.checkCancellation()
            return try lock.withLock {
                try Task.checkCancellation()
                guard let loadedModel else {
                    throw LocalLlamaError.runtimeUnavailable
                }

                var error = AutoCompLlamaError()
                let stopSequences = request.stopSequences
                let generated = request.prompt.withCString { prompt in
                    withCStringArray(stopSequences) { stopSequencePointers in
                        stopSequencePointers.withUnsafeBufferPointer { stopSequenceBuffer in
                            autocomp_llama_model_generate(
                                loadedModel,
                                prompt,
                                Int32(max(1, request.maxTokens)),
                                Float(request.temperature),
                                stopSequenceBuffer.baseAddress,
                                Int32(stopSequenceBuffer.count),
                                &error
                            )
                        }
                    }
                }
                guard let generated else {
                    throw LocalLlamaError.generationFailed(String(cString: autocomp_llama_error_message(&error)))
                }
                defer { autocomp_llama_string_free(generated) }
                try Task.checkCancellation()
                return String(cString: generated)
            }
        }.value
    }

    public func tokenizerProfile() async throws -> LocalLlamaTokenizerProfile {
        try lock.withLock {
            guard let loadedModel else {
                throw LocalLlamaError.runtimeUnavailable
            }

            var profile = AutoCompLlamaTokenizerProfile()
            var error = AutoCompLlamaError()
            guard autocomp_llama_model_tokenizer_profile(loadedModel, &profile, &error) else {
                throw LocalLlamaError.generationFailed(String(cString: autocomp_llama_error_message(&error)))
            }
            let specialTokenSignature = [
                "bos:\(profile.bos_token)",
                "eos:\(profile.eos_token)",
                "eot:\(profile.eot_token)",
                "nl:\(profile.newline_token)",
                "fim_pre:\(profile.fim_prefix_token)",
                "fim_suf:\(profile.fim_suffix_token)",
                "fim_mid:\(profile.fim_middle_token)"
            ].joined(separator: "|")

            return LocalLlamaTokenizerProfile(
                tokenizerKind: "llama-vocab-type-\(profile.vocabulary_type)",
                vocabularySize: Int(profile.vocabulary_size),
                specialTokenSignature: specialTokenSignature,
                supportsFillInMiddle: profile.supports_fill_in_middle
            )
        }
    }

    public func resetPromptCache() async {
        lock.withLock {
            guard let loadedModel else {
                return
            }
            autocomp_llama_model_reset_cache(loadedModel)
        }
    }

    public func promptCacheStats() async -> LlamaPromptCacheStats {
        cacheStats()
    }

    public func cacheStats() -> LlamaPromptCacheStats {
        lock.withLock {
            guard let loadedModel else {
                return .empty
            }
            let stats = autocomp_llama_model_cache_stats(loadedModel)
            return LlamaPromptCacheStats(
                hits: stats.hits,
                misses: stats.misses,
                resets: stats.resets,
                retainedPromptTokens: Int(stats.retained_prompt_tokens),
                contextTokens: stats.context_tokens
            )
        }
    }

    public func shutdown() async {
        lock.withLock {
            unloadLocked()
            releaseBackendLocked()
        }
    }

    private func retainBackendLocked() {
        guard !backendRetained else {
            return
        }
        backendLifecycle.retain()
        backendRetained = true
    }

    private func releaseBackendLocked() {
        guard backendRetained else {
            return
        }
        backendLifecycle.release()
        backendRetained = false
    }

    private func unloadLocked() {
        guard let loadedModel else {
            return
        }
        autocomp_llama_model_free(loadedModel)
        self.loadedModel = nil
    }

    private func enforceRAMLimit(configuration: LocalLlamaConfiguration) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: configuration.modelPath)
        let fileSize = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        guard fileSize <= configuration.maxRAMBytes else {
            let fileSizeLabel = ByteCountFormatter.string(
                fromByteCount: Int64(min(fileSize, UInt64(Int64.max))),
                countStyle: .memory
            )
            let limitLabel = ByteCountFormatter.string(
                fromByteCount: Int64(min(configuration.maxRAMBytes, UInt64(Int64.max))),
                countStyle: .memory
            )
            throw LocalLlamaError.allocationFailed(
                "Model file size \(fileSizeLabel) exceeds configured local memory limit \(limitLabel)."
            )
        }
    }

    static func loadError(message: String, code: Int32) -> LocalLlamaError {
        guard code == 3 || message.isAllocationFailureMessage else {
            return .loadFailed(message)
        }
        return .allocationFailed(message)
    }

    private func withCStringArray<Result>(
        _ strings: [String],
        _ body: ([UnsafePointer<CChar>?]) -> Result
    ) -> Result {
        var pointers: [UnsafePointer<CChar>?] = []

        func appendPointer(at index: Int) -> Result {
            guard index < strings.count else {
                return body(pointers)
            }

            return strings[index].withCString { pointer in
                pointers.append(pointer)
                defer {
                    pointers.removeLast()
                }
                return appendPointer(at: index + 1)
            }
        }

        return appendPointer(at: 0)
    }
}

final class LlamaBackendGlobalLifecycle: @unchecked Sendable {
    static let shared = LlamaBackendGlobalLifecycle(
        initialize: autocomp_llama_backend_init,
        free: autocomp_llama_backend_free
    )

    private let lock = NSLock()
    private let initialize: () -> Void
    private let free: () -> Void
    private var referenceCount = 0

    init(initialize: @escaping () -> Void, free: @escaping () -> Void) {
        self.initialize = initialize
        self.free = free
    }

    func retain() {
        lock.withLock {
            if referenceCount == 0 {
                initialize()
            }
            referenceCount += 1
        }
    }

    func release() {
        lock.withLock {
            guard referenceCount > 0 else {
                return
            }
            referenceCount -= 1
            if referenceCount == 0 {
                free()
            }
        }
    }
}

private extension String {
    var isAllocationFailureMessage: Bool {
        let value = lowercased()
        return value.contains("allocat")
            || value.contains("insufficient memory")
            || value.contains("out of memory")
            || value.contains("memory pressure")
    }
}
