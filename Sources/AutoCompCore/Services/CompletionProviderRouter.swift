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
    case remoteConsentRequired(RemoteCompletionConsentScope)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let kind):
            return "\(kind.displayName) completion is unavailable in this build."
        case .remoteConsentRequired(let scope):
            switch scope {
            case .remoteBackend:
                return "Remote completion requires explicit consent before autocomplete text is sent."
            case .remoteFallback:
                return "Remote fallback requires explicit consent before autocomplete text is sent."
            }
        }
    }
}

public protocol RemoteCompletionConsentChecking: Sendable {
    func hasConsent(for scope: RemoteCompletionConsentScope) -> Bool
}

public struct AllowingRemoteCompletionConsentChecker: RemoteCompletionConsentChecking {
    public init() {}

    public func hasConsent(for scope: RemoteCompletionConsentScope) -> Bool {
        true
    }
}

public struct CompletionProviderRouter: ClipboardContextAwareCompletionProvider, MultipleCompletionProvider, PromptCacheReportingCompletionProvider, RuntimeSwitchPreparingCompletionProvider, CompletionRoutingProviding {
    public let activeKind: CompletionEngineKind
    public let fallbackKind: CompletionEngineKind?
    private let providers: [CompletionEngineKind: CompletionProvider]
    private let remoteConsentChecker: any RemoteCompletionConsentChecking

    public init(
        activeKind: CompletionEngineKind = .remote,
        fallbackKind: CompletionEngineKind? = nil,
        providers: [CompletionEngineKind: CompletionProvider],
        remoteConsentChecker: any RemoteCompletionConsentChecking = AllowingRemoteCompletionConsentChecker()
    ) {
        self.activeKind = activeKind
        self.fallbackKind = fallbackKind
        self.providers = providers
        self.remoteConsentChecker = remoteConsentChecker
    }

    public var routingPolicy: CompletionRoutingPolicy {
        CompletionRoutingPolicy(activeKind: activeKind, fallbackKind: fallbackKind)
    }

    public func provider(for kind: CompletionEngineKind? = nil) -> CompletionProvider? {
        providers[kind ?? activeKind]
    }

    public func resetPromptCache() async {
        if let provider = provider() as? PromptCacheReportingCompletionProvider {
            await provider.resetPromptCache()
        }
        if let fallbackProvider = fallbackProvider() as? PromptCacheReportingCompletionProvider {
            await fallbackProvider.resetPromptCache()
        }
    }

    public func promptCacheStats() async -> LlamaPromptCacheStats? {
        guard activeKind == .localLlama,
              let provider = provider() as? PromptCacheReportingCompletionProvider else {
            return nil
        }
        return await provider.promptCacheStats()
    }

    public func prepareForRuntimeSwitch() async {
        for provider in providers.values {
            if let provider = provider as? RuntimeSwitchPreparingCompletionProvider {
                await provider.prepareForRuntimeSwitch()
            }
        }
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
        try requireRemoteConsent(for: activeKind, scope: .remoteBackend)
        guard let provider = provider() else {
            if let fallbackProvider = fallbackProvider() {
                try requireRemoteConsent(for: fallbackKind, scope: .remoteFallback)
                let suggestion = try await complete(
                    with: fallbackProvider,
                    context: context,
                    privacySettings: privacySettings,
                    visualContext: visualContext,
                    clipboardContext: clipboardContext
                )
                return routed(
                    suggestion,
                    deliveredBy: fallbackKind ?? activeKind,
                    primaryError: CompletionProviderRouterError.unavailable(activeKind)
                )
            }
            throw CompletionProviderRouterError.unavailable(activeKind)
        }

        do {
            let suggestion = try await complete(
                with: provider,
                context: context,
                privacySettings: privacySettings,
                visualContext: visualContext,
                clipboardContext: clipboardContext
            )
            return routed(suggestion, deliveredBy: activeKind)
        } catch {
            guard let fallbackProvider = fallbackProvider() else {
                throw error
            }
            try requireRemoteConsent(for: fallbackKind, scope: .remoteFallback)
            let suggestion = try await complete(
                with: fallbackProvider,
                context: context,
                privacySettings: privacySettings,
                visualContext: visualContext,
                clipboardContext: clipboardContext
            )
            return routed(suggestion, deliveredBy: fallbackKind ?? activeKind, primaryError: error)
        }
    }

    public func complete(
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?,
        clipboardContext: ClipboardContextSnapshot?,
        options: CompletionOptions
    ) async throws -> [Suggestion] {
        try requireRemoteConsent(for: activeKind, scope: .remoteBackend)
        guard let provider = provider() else {
            if let fallbackProvider = fallbackProvider() {
                try requireRemoteConsent(for: fallbackKind, scope: .remoteFallback)
                let suggestions = try await completeMultiple(
                    with: fallbackProvider,
                    context: context,
                    privacySettings: privacySettings,
                    visualContext: visualContext,
                    clipboardContext: clipboardContext,
                    options: options
                )
                return routed(
                    suggestions,
                    deliveredBy: fallbackKind ?? activeKind,
                    primaryError: CompletionProviderRouterError.unavailable(activeKind)
                )
            }
            throw CompletionProviderRouterError.unavailable(activeKind)
        }

        do {
            let suggestions = try await completeMultiple(
                with: provider,
                context: context,
                privacySettings: privacySettings,
                visualContext: visualContext,
                clipboardContext: clipboardContext,
                options: options
            )
            return routed(suggestions, deliveredBy: activeKind)
        } catch {
            guard let fallbackProvider = fallbackProvider() else {
                throw error
            }
            try requireRemoteConsent(for: fallbackKind, scope: .remoteFallback)
            let suggestions = try await completeMultiple(
                with: fallbackProvider,
                context: context,
                privacySettings: privacySettings,
                visualContext: visualContext,
                clipboardContext: clipboardContext,
                options: options
            )
            return routed(suggestions, deliveredBy: fallbackKind ?? activeKind, primaryError: error)
        }
    }

    private func fallbackProvider() -> CompletionProvider? {
        guard let fallbackKind,
              fallbackKind != activeKind else {
            return nil
        }

        return providers[fallbackKind]
    }

    private func requireRemoteConsent(
        for kind: CompletionEngineKind?,
        scope: RemoteCompletionConsentScope
    ) throws {
        guard kind == .remote,
              !remoteConsentChecker.hasConsent(for: scope) else {
            return
        }
        throw CompletionProviderRouterError.remoteConsentRequired(scope)
    }

    private func routed(
        _ suggestions: [Suggestion],
        deliveredBy deliveredKind: CompletionEngineKind,
        primaryError: Error? = nil
    ) -> [Suggestion] {
        suggestions.map { routed($0, deliveredBy: deliveredKind, primaryError: primaryError) }
    }

    private func routed(
        _ suggestion: Suggestion,
        deliveredBy deliveredKind: CompletionEngineKind,
        primaryError: Error? = nil
    ) -> Suggestion {
        var routedSuggestion = suggestion
        routedSuggestion.completionRoute = CompletionRoute(
            requestedKind: activeKind,
            deliveredKind: deliveredKind,
            fallbackErrorDescription: primaryError.map(Self.message)
        )
        return routedSuggestion
    }

    private static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    private func complete(
        with provider: CompletionProvider,
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?,
        clipboardContext: ClipboardContextSnapshot?
    ) async throws -> Suggestion {
        if let provider = provider as? ClipboardContextAwareCompletionProvider {
            return try await provider.complete(
                context: context,
                privacySettings: privacySettings,
                visualContext: visualContext,
                clipboardContext: clipboardContext
            )
        }
        if let provider = provider as? VisualContextAwareCompletionProvider {
            return try await provider.complete(
                context: context,
                privacySettings: privacySettings,
                visualContext: visualContext
            )
        }
        return try await provider.complete(context: context)
    }

    private func completeMultiple(
        with provider: CompletionProvider,
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?,
        clipboardContext: ClipboardContextSnapshot?,
        options: CompletionOptions
    ) async throws -> [Suggestion] {
        if let provider = provider as? MultipleCompletionProvider {
            return try await provider.complete(
                context: context,
                privacySettings: privacySettings,
                visualContext: visualContext,
                clipboardContext: clipboardContext,
                options: options
            )
        }
        return [
            try await complete(
                with: provider,
                context: context,
                privacySettings: privacySettings,
                visualContext: visualContext,
                clipboardContext: clipboardContext
            )
        ]
    }
}
