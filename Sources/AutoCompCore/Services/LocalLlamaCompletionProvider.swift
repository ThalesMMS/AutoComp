import Foundation

public struct LocalLlamaConfiguration: Codable, Equatable, Sendable {
    public var modelPath: String
    public var modelName: String
    public var maxTokens: Int
    public var maxRAMBytes: UInt64

    public init(
        modelPath: String,
        modelName: String = "local-llama",
        maxTokens: Int = 32,
        maxRAMBytes: UInt64 = 6_442_450_944
    ) {
        self.modelPath = modelPath
        self.modelName = modelName
        self.maxTokens = maxTokens
        self.maxRAMBytes = maxRAMBytes
    }
}

public enum LocalLlamaError: LocalizedError, Equatable, Sendable {
    case modelNotFound(String)
    case runtimeUnavailable
    case loadFailed(String)
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

    public init(backend: LocalLlamaRuntimeBackend = UnavailableLocalLlamaRuntimeBackend()) {
        self.backend = backend
    }

    public func load(configuration: LocalLlamaConfiguration) async throws {
        guard loadedModelPath != configuration.modelPath else {
            return
        }

        do {
            try await backend.loadModel(configuration: configuration)
            loadedModelPath = configuration.modelPath
        } catch let error as LocalLlamaError {
            throw error
        } catch {
            throw LocalLlamaError.loadFailed(String(describing: error))
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
        await backend.shutdown()
        loadedModelPath = nil
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

    public init(
        configuration: LocalLlamaConfiguration,
        requestFactory: CompletionRequestFactory = CompletionRequestFactory(),
        runtime: LocalLlamaRuntimeCore = LocalLlamaRuntimeCore(),
        promptCacheHintTracker: LlamaPromptCacheHintTracker = LlamaPromptCacheHintTracker()
    ) {
        self.configuration = configuration
        self.requestFactory = requestFactory
        self.runtime = runtime
        self.promptCacheHintTracker = promptCacheHintTracker
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
                maxTokens: configuration.maxTokens
            ),
            privacySettings: privacySettings,
            visualContext: visualContext,
            clipboardContext: clipboardContext
        )

        if await promptCacheHintTracker.observe(context: context, configuration: configuration) != nil {
            await runtime.resetPromptCache()
        }
        try await runtime.load(configuration: configuration)
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
}
