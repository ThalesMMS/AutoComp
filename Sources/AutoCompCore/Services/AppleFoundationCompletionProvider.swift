import Foundation
#if canImport(FoundationModels)
import FoundationModels
#endif

public enum AppleFoundationModelError: LocalizedError, Equatable, Sendable {
    case unavailable(String)
    case generationFailed(String)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .unavailable(let reason):
            return "Apple Intelligence completion is unavailable: \(reason)"
        case .generationFailed(let reason):
            return "Apple Intelligence completion failed: \(reason)"
        case .emptyResponse:
            return "Apple Intelligence completion returned an empty response."
        }
    }
}

public protocol AppleFoundationModelBackend: Sendable {
    func generate(prompt: String) async throws -> String
}

public struct AppleFoundationCompletionProvider: VisualContextAwareCompletionProvider {
    public let requestFactory: CompletionRequestFactory
    public let maxTokens: Int
    private let backend: AppleFoundationModelBackend

    public init(
        requestFactory: CompletionRequestFactory = CompletionRequestFactory(),
        maxTokens: Int = 32,
        backend: AppleFoundationModelBackend = SystemAppleFoundationModelBackend()
    ) {
        self.requestFactory = requestFactory
        self.maxTokens = maxTokens
        self.backend = backend
    }

    public func complete(context: TextContext) async throws -> Suggestion {
        try await complete(context: context, privacySettings: PrivacySettings(), visualContext: nil)
    }

    public func complete(
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?
    ) async throws -> Suggestion {
        let startedAt = ContinuousClock.now
        let completionRequest = requestFactory.makeRequest(
            for: context,
            configuration: RemoteCompletionConfiguration(
                baseURL: "apple-foundation://system",
                apiKey: "local",
                model: "apple-foundation",
                maxTokens: maxTokens
            ),
            privacySettings: privacySettings,
            visualContext: visualContext
        )

        let rawText: String
        do {
            rawText = try await backend.generate(prompt: completionRequest.prompt)
        } catch let error as AppleFoundationModelError {
            throw error
        } catch {
            throw AppleFoundationModelError.generationFailed(String(describing: error))
        }

        let text = SuggestionTextNormalizer.normalize(
            rawText: rawText,
            precedingText: context.textBeforeCursor,
            promptEchoCandidates: completionRequest.promptEchoCandidates
        )

        guard !text.isEmpty else {
            throw AppleFoundationModelError.emptyResponse
        }

        return Suggestion(
            baseContextID: context.id,
            visibleText: text,
            rawText: rawText,
            latencyMs: startedAt.duration(to: .now).milliseconds
        )
    }
}

public struct SystemAppleFoundationModelBackend: AppleFoundationModelBackend {
    public init() {}

    public func generate(prompt: String) async throws -> String {
        #if canImport(FoundationModels)
        guard #available(macOS 26.0, *) else {
            throw AppleFoundationModelError.unavailable("FoundationModels requires macOS 26.0 or newer.")
        }

        return try await generateWithFoundationModels(prompt: prompt)
        #else
        throw AppleFoundationModelError.unavailable("FoundationModels framework is not available in this SDK.")
        #endif
    }

    #if canImport(FoundationModels)
    @available(macOS 26.0, *)
    private func generateWithFoundationModels(prompt: String) async throws -> String {
        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            throw AppleFoundationModelError.unavailable("System language model state is \(model.availability).")
        }

        let session = LanguageModelSession(
            instructions: "You are AutoComp, a low-latency autocomplete engine. Return only the user's likely next words. Do not explain."
        )
        let response = try await session.respond(to: prompt)
        return response.content
    }
    #endif
}
