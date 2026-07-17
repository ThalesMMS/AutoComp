import AutoCompCore
internal import CLlamaBridge
import Foundation

private final class LlamaStreamBridgeContext: @unchecked Sendable {
    private let lock = NSLock()
    private let continuation: AsyncThrowingStream<LocalLlamaRuntimePartial, Error>.Continuation
    private let startedAt = ContinuousClock.now
    private var stopped = false
    private var lastSequence = 0

    init(continuation: AsyncThrowingStream<LocalLlamaRuntimePartial, Error>.Continuation) {
        self.continuation = continuation
    }

    func receive(text: UnsafePointer<CChar>?, sequence: Int32) -> Bool {
        guard let text else { return true }
        let partial: LocalLlamaRuntimePartial? = lock.withLock {
            guard !stopped else { return nil }
            lastSequence = max(lastSequence, Int(sequence))
            return LocalLlamaRuntimePartial(
                rawAccumulatedText: String(cString: text),
                providerSequence: lastSequence,
                isFinal: false,
                latencyMs: startedAt.duration(to: .now).milliseconds
            )
        }
        guard let partial else { return false }
        switch continuation.yield(partial) {
        case .terminated: return false
        case .enqueued, .dropped: return true
        @unknown default: return true
        }
    }

    func finish(rawText: String) {
        let final: LocalLlamaRuntimePartial? = lock.withLock {
            guard !stopped else { return nil }
            stopped = true
            lastSequence += 1
            return LocalLlamaRuntimePartial(
                rawAccumulatedText: rawText,
                providerSequence: lastSequence,
                isFinal: true,
                latencyMs: startedAt.duration(to: .now).milliseconds
            )
        }
        guard let final else { return }
        continuation.yield(final)
        continuation.finish()
    }

    func fail(_ error: Error) {
        let shouldFinish = lock.withLock {
            guard !stopped else { return false }
            stopped = true
            return true
        }
        if shouldFinish { continuation.finish(throwing: error) }
    }

    func cancel() {
        lock.withLock { stopped = true }
    }
}

private let autocompLlamaStreamCallback: @convention(c) (
    UnsafePointer<CChar>?,
    Int32,
    UnsafeMutableRawPointer?
) -> Bool = { text, sequence, rawContext in
    guard let rawContext else { return false }
    let context = Unmanaged<LlamaStreamBridgeContext>.fromOpaque(rawContext).takeUnretainedValue()
    return context.receive(text: text, sequence: sequence)
}

public final class LlamaCppRuntimeBackend: LocalLlamaRuntimeBackend, @unchecked Sendable {
    private let loadVocabularyOnly: Bool
    private let backendLifecycle: LlamaBackendGlobalLifecycle
    private let lock = NSLock()
    private var loadedModel: OpaquePointer?
    private var cachedExperimentalTokenProfile: AutoCompTokenProfile?
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

    public func generateCompletionStream(
        for request: CompletionRequest
    ) -> AsyncThrowingStream<LocalLlamaRuntimePartial, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let context = LlamaStreamBridgeContext(continuation: continuation)
            continuation.onTermination = { _ in context.cancel() }

            Task.detached(priority: .userInitiated) { [self, context] in
                let retainedContext = Unmanaged.passRetained(context)
                defer { retainedContext.release() }
                do {
                    let text = try lock.withLock {
                        guard let loadedModel else {
                            throw LocalLlamaError.runtimeUnavailable
                        }
                        var error = AutoCompLlamaError()
                        let generated = request.prompt.withCString { prompt in
                            withCStringArray(request.stopSequences) { stopSequencePointers in
                                stopSequencePointers.withUnsafeBufferPointer { stopSequenceBuffer in
                                    autocomp_llama_model_generate_stream(
                                        loadedModel,
                                        prompt,
                                        Int32(max(1, request.maxTokens)),
                                        Float(request.temperature),
                                        stopSequenceBuffer.baseAddress,
                                        Int32(stopSequenceBuffer.count),
                                        autocompLlamaStreamCallback,
                                        retainedContext.toOpaque(),
                                        &error
                                    )
                                }
                            }
                        }
                        guard let generated else {
                            throw LocalLlamaError.generationFailed(
                                String(cString: autocomp_llama_error_message(&error))
                            )
                        }
                        defer { autocomp_llama_string_free(generated) }
                        return String(cString: generated)
                    }
                    context.finish(rawText: text)
                } catch {
                    context.fail(error)
                }
            }
        }
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

    public func experimentalTokenProfile(modelFamily: String) async throws -> AutoCompTokenProfile {
        try await Task.detached(priority: .utility) { [self] in
            try Task.checkCancellation()
            return try lock.withLock {
                guard let loadedModel else { throw LocalLlamaError.runtimeUnavailable }
                if let cachedExperimentalTokenProfile,
                   cachedExperimentalTokenProfile.modelFamily == modelFamily {
                    return cachedExperimentalTokenProfile
                }
                var runtimeProfile = AutoCompLlamaTokenizerProfile()
                var error = AutoCompLlamaError()
                guard autocomp_llama_model_tokenizer_profile(loadedModel, &runtimeProfile, &error) else {
                    throw LocalLlamaError.generationFailed(String(cString: autocomp_llama_error_message(&error)))
                }
                var records: [AutoCompTokenRecord] = []
                records.reserveCapacity(Int(runtimeProfile.vocabulary_size))
                var specialTokenIDs = Set<Int32>()
                var stopTokenIDs = Set<Int32>()
                for token in 0..<runtimeProfile.vocabulary_size {
                    if token.isMultiple(of: 512) { try Task.checkCancellation() }
                    var metadata = AutoCompLlamaTokenMetadata()
                    guard autocomp_llama_model_token_metadata(
                        loadedModel, token, nil, 0, &metadata, &error
                    ) else {
                        throw LocalLlamaError.generationFailed(String(cString: autocomp_llama_error_message(&error)))
                    }
                    var bytes = [UInt8](repeating: 0, count: Int(metadata.byte_count))
                    let read = bytes.withUnsafeMutableBytes { rawBuffer in
                        autocomp_llama_model_token_metadata(
                            loadedModel,
                            token,
                            rawBuffer.baseAddress?.assumingMemoryBound(to: CChar.self),
                            Int32(rawBuffer.count),
                            &metadata,
                            &error
                        )
                    }
                    guard read else {
                        throw LocalLlamaError.generationFailed(String(cString: autocomp_llama_error_message(&error)))
                    }
                    let flags = AutoCompTokenFlags(rawValue: metadata.flags)
                    if flags.contains(.special) { specialTokenIDs.insert(token) }
                    if flags.contains(.stop) { stopTokenIDs.insert(token) }
                    records.append(AutoCompTokenRecord(
                        id: token,
                        bytes: Data(bytes),
                        flags: flags,
                        approximateDisplayWidth: metadata.approximate_display_width
                    ))
                }
                let profile = AutoCompTokenProfile(
                    modelFamily: modelFamily,
                    tokenizerDigest: AutoCompTokenProfileCodec.tokenizerDigest(records: records),
                    records: records,
                    specialTokenIDs: specialTokenIDs,
                    stopTokenIDs: stopTokenIDs
                )
                cachedExperimentalTokenProfile = profile
                return profile
            }
        }.value
    }

    public func topTokens(
        prompt: String,
        generatedTokenIDs: [Int32],
        allowedTokenIDs: [Int32]?,
        limit: Int
    ) async throws -> [AutoCompScoredToken] {
        try Task.checkCancellation()
        return try await Task.detached(priority: .userInitiated) { [self] in
            try Task.checkCancellation()
            return try lock.withLock {
                try Task.checkCancellation()
                guard let loadedModel else { throw LocalLlamaError.runtimeUnavailable }
                let boundedLimit = max(1, min(limit, 4_096))
                var resultTokens = [Int32](repeating: 0, count: boundedLimit)
                var resultLogProbabilities = [Float](repeating: 0, count: boundedLimit)
                var error = AutoCompLlamaError()
                let count = prompt.withCString { promptPointer in
                    generatedTokenIDs.withUnsafeBufferPointer { generatedBuffer in
                        let score: (UnsafePointer<Int32>?, Int32) -> Int32 = { allowedPointer, allowedCount in
                            resultTokens.withUnsafeMutableBufferPointer { tokenBuffer in
                                resultLogProbabilities.withUnsafeMutableBufferPointer { probabilityBuffer in
                                    autocomp_llama_model_top_tokens(
                                        loadedModel,
                                        promptPointer,
                                        generatedBuffer.baseAddress,
                                        Int32(generatedBuffer.count),
                                        allowedPointer,
                                        allowedCount,
                                        Int32(boundedLimit),
                                        tokenBuffer.baseAddress,
                                        probabilityBuffer.baseAddress,
                                        &error
                                    )
                                }
                            }
                        }
                        if let allowedTokenIDs {
                            return allowedTokenIDs.withUnsafeBufferPointer {
                                score($0.baseAddress, Int32($0.count))
                            }
                        }
                        return score(nil, 0)
                    }
                }
                guard count >= 0 else {
                    throw LocalLlamaError.generationFailed(String(cString: autocomp_llama_error_message(&error)))
                }
                try Task.checkCancellation()
                return (0..<Int(count)).map {
                    AutoCompScoredToken(
                        tokenID: resultTokens[$0],
                        logProbability: resultLogProbabilities[$0]
                    )
                }
            }
        }.value
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
                contextTokens: stats.context_tokens,
                reuse: LocalPromptReuseMetrics(
                    promptTokens: Int(stats.last_prompt_tokens),
                    commonPrefixTokens: Int(stats.last_common_prefix_tokens),
                    reusedTokens: Int(stats.last_reused_tokens),
                    prefillTokens: Int(stats.last_prefill_tokens),
                    tokenizationMilliseconds: Double(stats.last_tokenization_microseconds) / 1_000,
                    prefillMilliseconds: Double(stats.last_prefill_microseconds) / 1_000,
                    decodeMilliseconds: Double(stats.last_decode_microseconds) / 1_000,
                    cacheRebuilds: stats.cache_rebuilds
                ),
                lastResetReason: Self.cacheResetReason(event: stats.last_cache_miss_reason)
            )
        }
    }

    static func cacheResetReason(event: Int32) -> LlamaPromptCacheResetReason? {
        switch event {
        case 1: return .coldStart
        case 2: return .noCommonPrefix
        case 3: return .contextSizeChanged
        case 4: return .samplingChanged
        case 5: return .runtimeInconsistency
        default: return nil
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
        cachedExperimentalTokenProfile = nil
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
