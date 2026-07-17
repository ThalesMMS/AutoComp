import Foundation

public struct LocalLlamaConfiguration: Codable, Equatable, Sendable {
    public var modelPath: String
    public var modelName: String
    public var maxTokens: Int
    public var maxRAMBytes: UInt64
    public var stopSequences: CompletionStopSequences

    public init(
        modelPath: String,
        modelName: String = "local-llama",
        maxTokens: Int = 32,
        maxRAMBytes: UInt64 = CompletionBackendDefaults.localMaxRAMBytes,
        stopSequences: CompletionStopSequences = .conservativeDefault
    ) {
        self.modelPath = modelPath
        self.modelName = modelName
        self.maxTokens = maxTokens
        self.maxRAMBytes = maxRAMBytes
        self.stopSequences = stopSequences
    }
}

public struct LocalLlamaTokenizerProfile: Codable, Equatable, Sendable {
    public var tokenizerKind: String
    public var vocabularySize: Int
    public var specialTokenSignature: String
    public var supportsFillInMiddle: Bool

    public init(
        tokenizerKind: String,
        vocabularySize: Int,
        specialTokenSignature: String,
        supportsFillInMiddle: Bool
    ) {
        self.tokenizerKind = tokenizerKind
        self.vocabularySize = vocabularySize
        self.specialTokenSignature = specialTokenSignature
        self.supportsFillInMiddle = supportsFillInMiddle
    }

    public func isCompatible(with actual: LocalLlamaTokenizerProfile) -> Bool {
        tokenizerKind == actual.tokenizerKind
            && vocabularySize == actual.vocabularySize
            && specialTokenSignature == actual.specialTokenSignature
            && supportsFillInMiddle == actual.supportsFillInMiddle
    }

    public var cacheSignature: String {
        "\(tokenizerKind)|\(vocabularySize)|\(specialTokenSignature)|fim:\(supportsFillInMiddle)"
    }
}

public enum LocalLlamaRuntimeLoadState: String, Codable, Equatable, Sendable {
    case unloaded
    case loading
    case loaded
    case failed

    public var title: String {
        switch self {
        case .unloaded:
            return "Unloaded"
        case .loading:
            return "Loading"
        case .loaded:
            return "Loaded"
        case .failed:
            return "Failed"
        }
    }
}

public struct LocalLlamaRuntimeStatus: Codable, Equatable, Sendable {
    public var state: LocalLlamaRuntimeLoadState
    public var modelPath: String?
    public var message: String?

    public init(
        state: LocalLlamaRuntimeLoadState,
        modelPath: String? = nil,
        message: String? = nil
    ) {
        self.state = state
        self.modelPath = modelPath
        self.message = message
    }

    public static let unloaded = LocalLlamaRuntimeStatus(state: .unloaded)
}

public typealias LocalLlamaRuntimeStatusRecorder = @Sendable (LocalLlamaRuntimeStatus) async -> Void

public struct LocalLlamaRuntimePartial: Equatable, Sendable {
    public let rawAccumulatedText: String
    public let providerSequence: Int
    public let isFinal: Bool
    public let latencyMs: Int

    public init(
        rawAccumulatedText: String,
        providerSequence: Int,
        isFinal: Bool,
        latencyMs: Int
    ) {
        self.rawAccumulatedText = rawAccumulatedText
        self.providerSequence = providerSequence
        self.isFinal = isFinal
        self.latencyMs = latencyMs
    }
}

public enum LocalLlamaError: LocalizedError, Equatable, Sendable {
    case modelNotFound(String)
    case runtimeUnavailable
    case loadFailed(String)
    case allocationFailed(String)
    case generationFailed(String)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .modelNotFound(let path):
            return "Local model was not found at \(path)."
        case .runtimeUnavailable:
            return "Local Llama runtime is unavailable in this build."
        case .loadFailed(let reason):
            return "Local model failed to load: \(reason)"
        case .allocationFailed(let reason):
            return "Local model allocation failed: \(reason)"
        case .generationFailed(let reason):
            return "Local completion failed: \(reason)"
        case .emptyResponse:
            return "Local completion returned an empty response."
        }
    }
}

public protocol LocalLlamaRuntimeBackend: Sendable {
    func loadModel(configuration: LocalLlamaConfiguration) async throws
    func generateCompletion(for request: CompletionRequest) async throws -> String
    func generateCompletionStream(for request: CompletionRequest) -> AsyncThrowingStream<LocalLlamaRuntimePartial, Error>
    func tokenizerProfile() async throws -> LocalLlamaTokenizerProfile
    func experimentalTokenProfile(modelFamily: String) async throws -> AutoCompTokenProfile
    func topTokens(
        prompt: String,
        generatedTokenIDs: [Int32],
        allowedTokenIDs: [Int32]?,
        limit: Int
    ) async throws -> [AutoCompScoredToken]
    func resetPromptCache() async
    func promptCacheStats() async -> LlamaPromptCacheStats
    func shutdown() async
}

public extension LocalLlamaRuntimeBackend {
    func generateCompletionStream(for request: CompletionRequest) -> AsyncThrowingStream<LocalLlamaRuntimePartial, Error> {
        AsyncThrowingStream { continuation in
            Task {
                let startedAt = ContinuousClock.now
                do {
                    let text = try await generateCompletion(for: request)
                    continuation.yield(LocalLlamaRuntimePartial(
                        rawAccumulatedText: text,
                        providerSequence: 1,
                        isFinal: true,
                        latencyMs: startedAt.duration(to: .now).milliseconds
                    ))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func tokenizerProfile() async throws -> LocalLlamaTokenizerProfile {
        throw LocalLlamaError.runtimeUnavailable
    }

    func experimentalTokenProfile(modelFamily: String) async throws -> AutoCompTokenProfile {
        throw LocalLlamaError.runtimeUnavailable
    }

    func topTokens(
        prompt: String,
        generatedTokenIDs: [Int32],
        allowedTokenIDs: [Int32]?,
        limit: Int
    ) async throws -> [AutoCompScoredToken] {
        throw LocalLlamaError.runtimeUnavailable
    }

    func resetPromptCache() async {}
    func promptCacheStats() async -> LlamaPromptCacheStats { .empty }
}

public protocol PromptCacheReportingCompletionProvider: Sendable {
    func resetPromptCache() async
    func promptCacheStats() async -> LlamaPromptCacheStats?
}

public actor LocalLlamaRuntimeCore: AutoCompTokenScoringRuntime {
    private let backend: LocalLlamaRuntimeBackend
    private var loadedModelPath: String?
    private var runtimeStatus = LocalLlamaRuntimeStatus.unloaded

    public init(backend: LocalLlamaRuntimeBackend = UnavailableLocalLlamaRuntimeBackend()) {
        self.backend = backend
    }

    public func status() -> LocalLlamaRuntimeStatus {
        runtimeStatus
    }

    public func load(configuration: LocalLlamaConfiguration) async throws {
        guard loadedModelPath != configuration.modelPath else {
            runtimeStatus = LocalLlamaRuntimeStatus(state: .loaded, modelPath: configuration.modelPath)
            return
        }

        if loadedModelPath != nil {
            let previousModelPath = loadedModelPath
            await backend.shutdown()
            loadedModelPath = nil
            runtimeStatus = LocalLlamaRuntimeStatus(state: .unloaded, modelPath: previousModelPath)
        }

        runtimeStatus = LocalLlamaRuntimeStatus(state: .loading, modelPath: configuration.modelPath)
        do {
            try await backend.loadModel(configuration: configuration)
            loadedModelPath = configuration.modelPath
            runtimeStatus = LocalLlamaRuntimeStatus(state: .loaded, modelPath: configuration.modelPath)
        } catch let error as LocalLlamaError {
            runtimeStatus = Self.failedStatus(modelPath: configuration.modelPath, error: error)
            throw error
        } catch {
            let mappedError = LocalLlamaError.loadFailed(String(describing: error))
            runtimeStatus = Self.failedStatus(modelPath: configuration.modelPath, error: mappedError)
            throw mappedError
        }
    }

    public func generateCompletion(for request: CompletionRequest) async throws -> String {
        do {
            return try await backend.generateCompletion(for: request)
        } catch let error as LocalLlamaError {
            throw error
        } catch {
            throw LocalLlamaError.generationFailed(String(describing: error))
        }
    }

    public func generateCompletionStream(
        for request: CompletionRequest
    ) -> AsyncThrowingStream<LocalLlamaRuntimePartial, Error> {
        backend.generateCompletionStream(for: request)
    }

    public func tokenizerProfile() async throws -> LocalLlamaTokenizerProfile {
        try await backend.tokenizerProfile()
    }

    public func experimentalTokenProfile(modelFamily: String) async throws -> AutoCompTokenProfile {
        try await backend.experimentalTokenProfile(modelFamily: modelFamily)
    }

    public func topTokens(
        prompt: String,
        generatedTokenIDs: [Int32],
        allowedTokenIDs: [Int32]?,
        limit: Int
    ) async throws -> [AutoCompScoredToken] {
        try await backend.topTokens(
            prompt: prompt,
            generatedTokenIDs: generatedTokenIDs,
            allowedTokenIDs: allowedTokenIDs,
            limit: limit
        )
    }

    public func resetPromptCache() async {
        await backend.resetPromptCache()
    }

    public func promptCacheStats() async -> LlamaPromptCacheStats {
        await backend.promptCacheStats()
    }

    public func shutdown() async {
        let previousModelPath = loadedModelPath
        await backend.shutdown()
        loadedModelPath = nil
        runtimeStatus = LocalLlamaRuntimeStatus(state: .unloaded, modelPath: previousModelPath)
    }

    private static func failedStatus(modelPath: String, error: LocalLlamaError) -> LocalLlamaRuntimeStatus {
        LocalLlamaRuntimeStatus(
            state: .failed,
            modelPath: modelPath,
            message: error.errorDescription ?? String(describing: error)
        )
    }
}

public struct UnavailableLocalLlamaRuntimeBackend: LocalLlamaRuntimeBackend {
    public static let fallbackDiagnostic = FallbackDiagnostic(
        symbol: "UnavailableLocalLlamaRuntimeBackend",
        classification: .optionalBuildFeature,
        reason: "llama-runtime-not-linked",
        userMessage: "Local Llama runtime is unavailable in this build.",
        remediation: "Use an app build linked with the in-process Local Llama runtime or select another backend."
    )

    public var fallbackDiagnostic: FallbackDiagnostic {
        Self.fallbackDiagnostic
    }

    public init() {}

    public func loadModel(configuration: LocalLlamaConfiguration) async throws {
        throw LocalLlamaError.runtimeUnavailable
    }

    public func generateCompletion(for request: CompletionRequest) async throws -> String {
        throw LocalLlamaError.runtimeUnavailable
    }

    public func tokenizerProfile() async throws -> LocalLlamaTokenizerProfile {
        throw LocalLlamaError.runtimeUnavailable
    }

    public func resetPromptCache() async {}
    public func promptCacheStats() async -> LlamaPromptCacheStats { .empty }

    public func shutdown() async {}
}

public struct LocalLlamaCompletionProvider: PersonalizationContextAwareCompletionProvider, PromptCacheReportingCompletionProvider, RuntimeSwitchPreparingCompletionProvider, StreamingCompletionProvider {
    public let streamingCompletionCapability: StreamingCompletionCapability? = .init(route: .localLlama)
    public let configuration: LocalLlamaConfiguration
    public let requestFactory: CompletionRequestFactory
    private let runtime: LocalLlamaRuntimeCore
    private let promptCacheHintTracker: LlamaPromptCacheHintTracker
    private let frozenSideContextStore: FrozenPromptSideContextStore
    private let runtimeStatusRecorder: LocalLlamaRuntimeStatusRecorder?

    public init(
        configuration: LocalLlamaConfiguration,
        requestFactory: CompletionRequestFactory = CompletionRequestFactory(),
        runtime: LocalLlamaRuntimeCore = LocalLlamaRuntimeCore(),
        promptCacheHintTracker: LlamaPromptCacheHintTracker = LlamaPromptCacheHintTracker(),
        frozenSideContextStore: FrozenPromptSideContextStore = FrozenPromptSideContextStore(),
        runtimeStatusRecorder: LocalLlamaRuntimeStatusRecorder? = nil
    ) {
        self.configuration = configuration
        self.requestFactory = requestFactory
        self.runtime = runtime
        self.promptCacheHintTracker = promptCacheHintTracker
        self.frozenSideContextStore = frozenSideContextStore
        self.runtimeStatusRecorder = runtimeStatusRecorder
    }

    public func complete(
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?,
        clipboardContext: ClipboardContextSnapshot?,
        personalizationSamples: [PersonalizationSample]
    ) async throws -> Suggestion {
        let startedAt = ContinuousClock.now
        let completionRequest = try await prepareCompletionRequest(
            context: context,
            privacySettings: privacySettings,
            visualContext: visualContext,
            clipboardContext: clipboardContext,
            personalizationSamples: personalizationSamples
        )
        let rawText = try await runtime.generateCompletion(for: completionRequest)
        let text = SuggestionTextNormalizer.normalize(
            rawText: rawText,
            request: completionRequest
        )

        guard !text.isEmpty else {
            throw LocalLlamaError.emptyResponse
        }

        return Suggestion(
            baseContextID: context.id,
            visibleText: text,
            rawText: rawText,
            latencyMs: startedAt.duration(to: .now).milliseconds
        )
    }

    public func streamCompletion(
        request: ProviderInvocation.Request,
        metadata: StreamingCompletionMetadata
    ) -> AsyncThrowingStream<CompletionPartial, Error> {
        AsyncThrowingStream(bufferingPolicy: .bufferingNewest(1)) { continuation in
            let task = Task {
                do {
                    let completionRequest = try await prepareCompletionRequest(
                        context: request.context,
                        privacySettings: request.privacySettings,
                        visualContext: request.visualContext,
                        clipboardContext: request.clipboardContext,
                        personalizationSamples: request.personalizationSamples
                    )
                    let route = CompletionRoute(
                        requestedKind: metadata.requestedRoute,
                        deliveredKind: .localLlama
                    )
                    for try await runtimePartial in await runtime.generateCompletionStream(for: completionRequest) {
                        try Task.checkCancellation()
                        let text = SuggestionTextNormalizer.normalize(
                            rawText: runtimePartial.rawAccumulatedText,
                            request: completionRequest
                        )
                        if text.isEmpty && !runtimePartial.isFinal { continue }
                        guard !text.isEmpty else { throw LocalLlamaError.emptyResponse }
                        continuation.yield(CompletionPartial(
                            metadata: metadata,
                            accumulatedText: text,
                            rawAccumulatedText: runtimePartial.rawAccumulatedText,
                            providerSequence: runtimePartial.providerSequence,
                            route: route,
                            phase: runtimePartial.isFinal ? .final : .partial,
                            latencyMs: runtimePartial.latencyMs
                        ))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func prepareCompletionRequest(
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?,
        clipboardContext: ClipboardContextSnapshot?,
        personalizationSamples: [PersonalizationSample]
    ) async throws -> CompletionRequest {
        let frozen = await frozenSideContextStore.resolve(
            textContext: context,
            privacySettings: privacySettings,
            visualContext: visualContext,
            clipboardContext: clipboardContext,
            personalizationSamples: personalizationSamples
        )
        let stableContext = context.copy(
            languageHint: .some(frozen.context.languageHint),
            captureSources: frozen.context.captureSources
        )
        let completionRequest = requestFactory.makeRequest(
            for: stableContext,
            configuration: RemoteCompletionConfiguration(
                baseURL: "local://in-process",
                apiKey: "local",
                model: configuration.modelName,
                maxTokens: configuration.maxTokens,
                stopSequences: configuration.stopSequences
            ),
            privacySettings: privacySettings,
            visualContext: frozen.context.visualContext,
            clipboardContext: frozen.context.clipboardContext,
            personalizationSamples: frozen.context.personalizationSamples
        )

        try await loadRuntime()
        let tokenizerProfile = try? await runtime.tokenizerProfile()
        let tokenizerSignature = tokenizerProfile?.cacheSignature
        let resetReason = await promptCacheHintTracker.observe(
            context: context,
            configuration: configuration,
            request: completionRequest,
            tokenizerSignature: tokenizerSignature,
            privacySettings: privacySettings,
            forcedResetReason: frozen.resetReason
        )
        if resetReason != nil { await runtime.resetPromptCache() }
        return completionRequest
    }

    public func shutdown() async {
        await promptCacheHintTracker.reset()
        await frozenSideContextStore.reset()
        await runtime.shutdown()
        await recordRuntimeStatus(await runtime.status())
    }

    public func resetPromptCache() async {
        await promptCacheHintTracker.reset()
        await frozenSideContextStore.reset()
        await runtime.resetPromptCache()
    }

    public func promptCacheStats() async -> LlamaPromptCacheStats? {
        let stats = await runtime.promptCacheStats()
        let resetReason = await promptCacheHintTracker.lastReason() ?? stats.lastResetReason
        return stats.recording(resetReason: resetReason)
    }

    public func prepareForRuntimeSwitch() async {
        await shutdown()
    }

    private func loadRuntime() async throws {
        let currentStatus = await runtime.status()
        if currentStatus.state != .loaded || currentStatus.modelPath != configuration.modelPath {
            await recordRuntimeStatus(LocalLlamaRuntimeStatus(state: .loading, modelPath: configuration.modelPath))
        }

        do {
            try await runtime.load(configuration: configuration)
            await recordRuntimeStatus(await runtime.status())
        } catch {
            await recordRuntimeStatus(await runtime.status())
            throw error
        }
    }

    private func recordRuntimeStatus(_ status: LocalLlamaRuntimeStatus) async {
        await runtimeStatusRecorder?(status)
    }
}
