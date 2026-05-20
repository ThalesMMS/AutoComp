import Foundation

public enum CompletionEngineKind: String, Codable, CaseIterable, Sendable {
    case remote
    case localLlama
    case appleIntelligence

    public var displayName: String {
        switch self {
        case .remote:
            return "Remote OpenAI-compatible"
        case .localLlama:
            return "Local Llama"
        case .appleIntelligence:
            return "Apple Intelligence"
        }
    }
}

public enum CompletionProviderRouterError: LocalizedError, Equatable, Sendable {
    case unavailable(CompletionEngineKind)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let kind):
            return "\(kind.displayName) completion is unavailable in this build."
        }
    }
}

public struct CompletionProviderRouter: VisualContextAwareCompletionProvider {
    public let activeKind: CompletionEngineKind
    public let fallbackKind: CompletionEngineKind?
    private let providers: [CompletionEngineKind: CompletionProvider]

    public init(
        activeKind: CompletionEngineKind = .remote,
        fallbackKind: CompletionEngineKind? = nil,
        providers: [CompletionEngineKind: CompletionProvider]
    ) {
        self.activeKind = activeKind
        self.fallbackKind = fallbackKind
        self.providers = providers
    }

    public func provider(for kind: CompletionEngineKind? = nil) -> CompletionProvider? {
        providers[kind ?? activeKind]
    }

    public func complete(context: TextContext) async throws -> Suggestion {
        try await complete(
            context: context,
            privacySettings: PrivacySettings(),
            visualContext: nil
        )
    }

    public func complete(
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?
    ) async throws -> Suggestion {
        guard let provider = provider() else {
            if let fallbackProvider = fallbackProvider() {
                return try await complete(
                    with: fallbackProvider,
                    context: context,
                    privacySettings: privacySettings,
                    visualContext: visualContext
                )
            }
            throw CompletionProviderRouterError.unavailable(activeKind)
        }

        do {
            return try await complete(
                with: provider,
                context: context,
                privacySettings: privacySettings,
                visualContext: visualContext
            )
        } catch {
            guard let fallbackProvider = fallbackProvider() else {
                throw error
            }
            return try await complete(
                with: fallbackProvider,
                context: context,
                privacySettings: privacySettings,
                visualContext: visualContext
            )
        }
    }

    private func fallbackProvider() -> CompletionProvider? {
        guard let fallbackKind,
              fallbackKind != activeKind else {
            return nil
        }

        return providers[fallbackKind]
    }

    private func complete(
        with provider: CompletionProvider,
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?
    ) async throws -> Suggestion {
        if let provider = provider as? VisualContextAwareCompletionProvider {
            return try await provider.complete(
                context: context,
                privacySettings: privacySettings,
                visualContext: visualContext
            )
        }
        return try await provider.complete(context: context)
    }
}
