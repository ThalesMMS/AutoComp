#if AUTOCOMP_CONSTRAINED_LOCAL_COMPLETION
import Foundation

public struct ConstrainedLocalCompletionConfiguration: Equatable, Sendable {
    public var localConfiguration: LocalLlamaConfiguration
    public var expectedTokenizerProfile: LocalLlamaTokenizerProfile?
    public var currentWordTypoGuardEnabled: Bool

    public init(
        localConfiguration: LocalLlamaConfiguration,
        expectedTokenizerProfile: LocalLlamaTokenizerProfile? = nil,
        currentWordTypoGuardEnabled: Bool = false
    ) {
        self.localConfiguration = localConfiguration
        self.expectedTokenizerProfile = expectedTokenizerProfile
        self.currentWordTypoGuardEnabled = currentWordTypoGuardEnabled
    }
}

public enum ConstrainedLocalCompletionError: LocalizedError, Equatable, Sendable {
    case tokenizerProfileMismatch(
        expected: LocalLlamaTokenizerProfile,
        actual: LocalLlamaTokenizerProfile
    )
    case emptyCandidate
    case currentWordTypoGuardRejected

    public var errorDescription: String? {
        switch self {
        case .tokenizerProfileMismatch:
            return "Constrained local completion tokenizer profile does not match this model."
        case .emptyCandidate:
            return "Constrained local completion produced no usable candidate."
        case .currentWordTypoGuardRejected:
            return "Constrained local completion rejected a likely current-word typo."
        }
    }
}

public struct ConstrainedLocalCompletionProvider: PersonalizationContextAwareCompletionProvider, PromptCacheReportingCompletionProvider, RuntimeSwitchPreparingCompletionProvider {
    public let configuration: ConstrainedLocalCompletionConfiguration
    public let requestFactory: CompletionRequestFactory
    private let runtime: LocalLlamaRuntimeCore
    private let promptCacheHintTracker: LlamaPromptCacheHintTracker
    private let runtimeStatusRecorder: LocalLlamaRuntimeStatusRecorder?

    public init(
        configuration: ConstrainedLocalCompletionConfiguration,
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

    public init(
        localConfiguration: LocalLlamaConfiguration,
        requestFactory: CompletionRequestFactory = CompletionRequestFactory(),
        runtime: LocalLlamaRuntimeCore = LocalLlamaRuntimeCore(),
        promptCacheHintTracker: LlamaPromptCacheHintTracker = LlamaPromptCacheHintTracker(),
        runtimeStatusRecorder: LocalLlamaRuntimeStatusRecorder? = nil
    ) {
        self.init(
            configuration: ConstrainedLocalCompletionConfiguration(localConfiguration: localConfiguration),
            requestFactory: requestFactory,
            runtime: runtime,
            promptCacheHintTracker: promptCacheHintTracker,
            runtimeStatusRecorder: runtimeStatusRecorder
        )
    }

    public func complete(
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?,
        clipboardContext: ClipboardContextSnapshot?,
        personalizationSamples: [PersonalizationSample]
    ) async throws -> Suggestion {
        let startedAt = ContinuousClock.now
        let localConfiguration = configuration.localConfiguration
        let completionRequest = requestFactory.makeRequest(
            for: context,
            configuration: RemoteCompletionConfiguration(
                baseURL: "local://constrained-in-process",
                apiKey: "local",
                model: localConfiguration.modelName,
                maxTokens: localConfiguration.maxTokens,
                stopSequences: localConfiguration.stopSequences
            ),
            privacySettings: privacySettings,
            visualContext: visualContext,
            clipboardContext: clipboardContext,
            personalizationSamples: personalizationSamples
        )

        if await promptCacheHintTracker.observe(context: context, configuration: localConfiguration) != nil {
            await runtime.resetPromptCache()
        }
        try await loadRuntimeAndValidateTokenizerProfile()

        let rawText = try await runtime.generateCompletion(for: completionRequest)
        let normalizedText = SuggestionTextNormalizer.normalize(
            rawText: rawText,
            request: completionRequest
        )
        let constrainedText = try constrain(
            normalizedText,
            request: completionRequest
        )

        return Suggestion(
            baseContextID: context.id,
            visibleText: constrainedText,
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

    private func loadRuntimeAndValidateTokenizerProfile() async throws {
        let localConfiguration = configuration.localConfiguration
        let currentStatus = await runtime.status()
        if currentStatus.state != .loaded || currentStatus.modelPath != localConfiguration.modelPath {
            await recordRuntimeStatus(LocalLlamaRuntimeStatus(state: .loading, modelPath: localConfiguration.modelPath))
        }

        do {
            try await runtime.load(configuration: localConfiguration)
            let actualProfile = try await runtime.tokenizerProfile()
            if let expectedProfile = configuration.expectedTokenizerProfile,
               !expectedProfile.isCompatible(with: actualProfile) {
                throw ConstrainedLocalCompletionError.tokenizerProfileMismatch(
                    expected: expectedProfile,
                    actual: actualProfile
                )
            }
            await recordRuntimeStatus(await runtime.status())
        } catch {
            await recordRuntimeStatus(await runtime.status())
            throw error
        }
    }

    private func constrain(
        _ normalizedText: String,
        request: CompletionRequest
    ) throws -> String {
        var candidate = normalizedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !candidate.isEmpty else {
            throw ConstrainedLocalCompletionError.emptyCandidate
        }

        if configuration.currentWordTypoGuardEnabled,
           beginsInsideCurrentWord(candidate, request: request) {
            throw ConstrainedLocalCompletionError.currentWordTypoGuardRejected
        }

        if let suffix = request.truncatedTextAfterCursor {
            candidate = try removingSuffixDuplication(from: candidate, suffix: suffix)
        }

        guard !candidate.isEmpty else {
            throw ConstrainedLocalCompletionError.emptyCandidate
        }
        return candidate
    }

    private func beginsInsideCurrentWord(
        _ candidate: String,
        request: CompletionRequest
    ) -> Bool {
        guard let previous = request.truncatedTextBeforeCursor.last,
              let next = candidate.first else {
            return false
        }
        return previous.isLetter || previous.isNumber
            ? next.isLetter || next.isNumber
            : false
    }

    private func removingSuffixDuplication(
        from candidate: String,
        suffix: String
    ) throws -> String {
        let normalizedSuffix = suffix.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSuffix.isEmpty else {
            return candidate
        }

        if candidate == normalizedSuffix || normalizedSuffix.hasPrefix(candidate) {
            throw ConstrainedLocalCompletionError.emptyCandidate
        }
        if candidate.hasPrefix(normalizedSuffix) {
            throw ConstrainedLocalCompletionError.emptyCandidate
        }

        let overlap = suffixOverlapLength(candidate: candidate, suffix: normalizedSuffix)
        guard overlap > 0 else {
            return candidate
        }

        let end = candidate.index(candidate.endIndex, offsetBy: -overlap)
        return String(candidate[..<end]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func suffixOverlapLength(candidate: String, suffix: String) -> Int {
        let candidateCharacters = Array(candidate)
        let suffixCharacters = Array(suffix)
        let limit = min(candidateCharacters.count, suffixCharacters.count)
        guard limit > 0 else {
            return 0
        }

        var longest = 0
        for length in 1...limit {
            let candidateTail = candidateCharacters.suffix(length)
            let suffixHead = suffixCharacters.prefix(length)
            if Array(candidateTail) == Array(suffixHead) {
                longest = length
            }
        }
        return longest
    }

    private func recordRuntimeStatus(_ status: LocalLlamaRuntimeStatus) async {
        await runtimeStatusRecorder?(status)
    }
}
#endif
