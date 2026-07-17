import Foundation

/// Pipeline step responsible for calling the completion provider.
///
/// This step is intentionally small: it takes a fully-prepared `ProviderInvocation.Request`,
/// performs the async provider call, and returns either a published payload or a discard.
public struct ProviderInvocationStep: SuggestionPipeline.Step {
    public typealias Payload = Suggestion

    private let provider: any CompletionProvider
    private let requestProvider: @Sendable (SuggestionPipeline.RequestContext) -> ProviderInvocation.Request?
    private let timeout: Duration?
    private let errorMapper: ProviderInvocationErrorMapper
    private let streamingConfiguration: StreamingCompletionConfiguration
    private let streamingMetadata: StreamingCompletionMetadata?
    private let onPartial: @Sendable (CompletionPartial) async -> Void

    public init(
        provider: any CompletionProvider,
        timeout: Duration? = nil,
        errorMapper: ProviderInvocationErrorMapper = ProviderInvocationErrorMapper(),
        requestProvider: @escaping @Sendable (SuggestionPipeline.RequestContext) -> ProviderInvocation.Request? = { $0.providerInvocationRequest },
        streamingConfiguration: StreamingCompletionConfiguration = .disabled,
        streamingMetadata: StreamingCompletionMetadata? = nil,
        onPartial: @escaping @Sendable (CompletionPartial) async -> Void = { _ in }
    ) {
        self.provider = provider
        self.timeout = timeout
        self.errorMapper = errorMapper
        self.streamingConfiguration = streamingConfiguration
        self.streamingMetadata = streamingMetadata
        self.onPartial = onPartial
        self.requestProvider = requestProvider
    }

    public func handle(context: inout SuggestionPipeline.RequestContext) async -> SuggestionPipeline.Outcome<Suggestion> {
        guard let request = requestProvider(context) else {
            return .discard(.init(kind: .ineligible, message: "Missing provider request"))
        }

        do {
            let suggestions: [Suggestion]
            if let timeout {
                suggestions = try await withThrowingTaskGroup(of: [Suggestion].self) { group in
                    group.addTask {
                        try await invokeProvider(request: request)
                    }
                    group.addTask {
                        try await Task.sleep(for: timeout)
                        throw ProviderInvocationTimeoutError()
                    }

                    defer { group.cancelAll() }
                    guard let first = try await group.next() else {
                        throw CancellationError()
                    }
                    return first
                }
            } else {
                suggestions = try await invokeProvider(request: request)
            }

            let suggestion = Self.preparedSuggestion(from: suggestions, context: request.context)
            if suggestion.visibleText.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines).isEmpty {
                return .discard(.init(kind: .emptyResponse, message: "Empty completion"))
            }

            context.suggestion = suggestion
            return .publish(suggestion)
        } catch is CancellationError {
            return .discard(.cancelled)
        } catch is ProviderInvocationTimeoutError {
            return .failure(.init(kind: .error, message: "timeout"))
        } catch {
            return .failure(errorMapper.map(error))
        }
    }

    private func invokeProvider(request: ProviderInvocation.Request) async throws -> [Suggestion] {
        if let streamingProvider = provider as? any StreamingCompletionProvider,
           streamingConfiguration.enables(streamingProvider.streamingCompletionCapability),
           request.options.suggestionCount == 1,
           let streamingMetadata {
            return [try await streamedSuggestion(
                provider: streamingProvider,
                request: request,
                metadata: streamingMetadata
            )]
        }
        return try await provider.completeSuggestions(request: request)
    }

    private func streamedSuggestion(
        provider: any StreamingCompletionProvider,
        request: ProviderInvocation.Request,
        metadata: StreamingCompletionMetadata
    ) async throws -> Suggestion {
        var finalPartial: CompletionPartial?
        for try await partial in provider.streamCompletion(request: request, metadata: metadata) {
            try Task.checkCancellation()
            guard partial.metadata == metadata else { continue }
            await onPartial(partial)
            if partial.isFinal {
                finalPartial = partial
                break
            }
        }
        guard let finalPartial else {
            throw ProviderInvocationStreamingError.missingFinal
        }
        return Suggestion(
            baseContextID: request.context.id,
            visibleText: finalPartial.accumulatedText,
            traceContext: metadata.traceContext,
            streamingMetadata: SuggestionStreamingMetadata(
                traceID: metadata.traceContext.traceID,
                workID: metadata.workID,
                providerSequence: finalPartial.providerSequence,
                isFinal: true
            ),
            rawText: finalPartial.rawAccumulatedText,
            completionRoute: finalPartial.route,
            latencyMs: finalPartial.latencyMs
        )
    }

    private static func preparedSuggestion(from suggestions: [Suggestion], context: TextContext) -> Suggestion {
        let nonEmpty = suggestions
            .filter { !$0.visibleText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .prefix(3)
        guard let first = nonEmpty.first else {
            return Suggestion(baseContextID: context.id, visibleText: "", latencyMs: 0)
        }
        let alternatives = nonEmpty.map {
            SuggestionAlternative(visibleText: $0.visibleText, rawText: $0.rawText)
        }
        guard alternatives.count > 1 else {
            return first
        }
        return Suggestion(
            baseContextID: context.id,
            visibleText: first.visibleText,
            rawText: first.rawText,
            alternatives: alternatives,
            completionRoute: first.completionRoute,
            latencyMs: first.latencyMs
        )
    }
}

private struct ProviderInvocationTimeoutError: Error {}
private enum ProviderInvocationStreamingError: Error {
    case missingFinal
}

private extension CompletionProvider {
    func completeSuggestions(request: ProviderInvocation.Request) async throws -> [Suggestion] {
        if let provider = self as? any MultiplePersonalizationContextAwareCompletionProvider {
            return try await provider.complete(
                context: request.context,
                privacySettings: request.privacySettings,
                visualContext: request.visualContext,
                clipboardContext: request.clipboardContext,
                personalizationSamples: request.personalizationSamples,
                options: request.options
            )
        }

        if let provider = self as? any PersonalizationContextAwareCompletionProvider {
            return [
                try await provider.complete(
                    context: request.context,
                    privacySettings: request.privacySettings,
                    visualContext: request.visualContext,
                    clipboardContext: request.clipboardContext,
                    personalizationSamples: request.personalizationSamples
                )
            ]
        }

        if let provider = self as? any MultipleCompletionProvider {
            return try await provider.complete(
                context: request.context,
                privacySettings: request.privacySettings,
                visualContext: request.visualContext,
                clipboardContext: request.clipboardContext,
                options: request.options
            )
        }

        if let provider = self as? any ClipboardContextAwareCompletionProvider {
            return [
                try await provider.complete(
                    context: request.context,
                    privacySettings: request.privacySettings,
                    visualContext: request.visualContext,
                    clipboardContext: request.clipboardContext
                )
            ]
        }

        if let provider = self as? any VisualContextAwareCompletionProvider {
            return [
                try await provider.complete(
                    context: request.context,
                    privacySettings: request.privacySettings,
                    visualContext: request.visualContext
                )
            ]
        }

        return [try await complete(context: request.context)]
    }
}
