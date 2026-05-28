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
        maxRAMBytes: UInt64 = 6_442_450_944,
        stopSequences: CompletionStopSequences = .conservativeDefault
    ) {
        self.modelPath = modelPath
        self.modelName = modelName
        self.maxTokens = maxTokens
        self.maxRAMBytes = maxRAMBytes
        self.stopSequences = stopSequences
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
    func resetPromptCache() async
    func promptCacheStats() async -> LlamaPromptCacheStats
    func shutdown() async
}

public extension LocalLlamaRuntimeBackend {
    func resetPromptCache() async {}
    func promptCacheStats() async -> LlamaPromptCacheStats { .empty }
}

public protocol PromptCacheReportingCompletionProvider: Sendable {
    func resetPromptCache() async
    func promptCacheStats() async -> LlamaPromptCacheStats?
}

public actor LocalLlamaRuntimeCore {
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
    public init() {}

    public func loadModel(configuration: LocalLlamaConfiguration) async throws {
        throw LocalLlamaError.runtimeUnavailable
    }

    public func generateCompletion(for request: CompletionRequest) async throws -> String {
        throw LocalLlamaError.runtimeUnavailable
    }

    public func resetPromptCache() async {}
    public func promptCacheStats() async -> LlamaPromptCacheStats { .empty }

    public func shutdown() async {}
}

public struct LocalLlamaCompletionProvider: ClipboardContextAwareCompletionProvider, PromptCacheReportingCompletionProvider, RuntimeSwitchPreparingCompletionProvider {
    public let configuration: LocalLlamaConfiguration
    public let requestFactory: CompletionRequestFactory
    private let runtime: LocalLlamaRuntimeCore
    private let promptCacheHintTracker: LlamaPromptCacheHintTracker
    private let runtimeStatusRecorder: LocalLlamaRuntimeStatusRecorder?

    public init(
        configuration: LocalLlamaConfiguration,
        requestFactory: CompletionRequestFactory = CompletionRequestFactory(),
        runtime: LocalLlamaRuntimeCore = LocalLlamaRuntimeCore(),
        promptCacheHintTracker: LlamaPromptCacheHintTracker = LlamaPromptCacheHintTracker(),
        runtimeStatusRecorder: LocalLlamaRuntimeStatusRecorder? = nil
    ) {
        self.configuration = configuration
        self.requestFactory = requestFactory
        self.runtime = runtime
        self.promptCacheHintTracker = promptCacheHintTracker
        self.runtimeStatusRecorder = runtimeStatusRecorder
    }

    public func complete(context: TextContext) async throws -> Suggestion {
        try await complete(context: context, privacySettings: PrivacySettings(), visualContext: nil)
    }

    public func complete(
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?
    ) async throws -> Suggestion {
        try await complete(
            context: context,
            privacySettings: privacySettings,
            visualContext: visualContext,
            clipboardContext: nil
        )
    }

    public func complete(
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?,
        clipboardContext: ClipboardContextSnapshot?
    ) async throws -> Suggestion {
        let startedAt = ContinuousClock.now
        let completionRequest = requestFactory.makeRequest(
            for: context,
            configuration: RemoteCompletionConfiguration(
                baseURL: "local://in-process",
                apiKey: "local",
                model: configuration.modelName,
                maxTokens: configuration.maxTokens,
                stopSequences: configuration.stopSequences
            ),
            privacySettings: privacySettings,
            visualContext: visualContext,
            clipboardContext: clipboardContext
        )

        if await promptCacheHintTracker.observe(context: context, configuration: configuration) != nil {
            await runtime.resetPromptCache()
        }
        try await loadRuntime()
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

    public func shutdown() async {
        await promptCacheHintTracker.reset()
        await runtime.shutdown()
        await recordRuntimeStatus(await runtime.status())
    }

    public func resetPromptCache() async {
        await promptCacheHintTracker.reset()
        await runtime.resetPromptCache()
    }

    public func promptCacheStats() async -> LlamaPromptCacheStats? {
        await runtime.promptCacheStats()
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
