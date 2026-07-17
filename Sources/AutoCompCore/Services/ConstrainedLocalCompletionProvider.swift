#if AUTOCOMP_CONSTRAINED_LOCAL_COMPLETION
import Foundation

public struct ConstrainedLocalCompletionConfiguration: Equatable, Sendable {
    public var localConfiguration: LocalLlamaConfiguration
    public var expectedTokenizerProfile: LocalLlamaTokenizerProfile?
    public var currentWordTypoGuardEnabled: Bool
    public var midWordHealingEnabled: Bool
    public var multiBranchDecoderEnabled: Bool
    public var tokenProfilePath: String?
    public var multiBranchPolicy: AutoCompMultiBranchDecodePolicy

    public init(
        localConfiguration: LocalLlamaConfiguration,
        expectedTokenizerProfile: LocalLlamaTokenizerProfile? = nil,
        currentWordTypoGuardEnabled: Bool = false,
        midWordHealingEnabled: Bool = false,
        multiBranchDecoderEnabled: Bool = false,
        tokenProfilePath: String? = nil,
        multiBranchPolicy: AutoCompMultiBranchDecodePolicy = AutoCompMultiBranchDecodePolicy()
    ) {
        self.localConfiguration = localConfiguration
        self.expectedTokenizerProfile = expectedTokenizerProfile
        self.currentWordTypoGuardEnabled = currentWordTypoGuardEnabled
        self.midWordHealingEnabled = midWordHealingEnabled
        self.multiBranchDecoderEnabled = multiBranchDecoderEnabled
        self.tokenProfilePath = tokenProfilePath
        self.multiBranchPolicy = multiBranchPolicy
    }
}

public enum ConstrainedLocalCompletionError: LocalizedError, Equatable, Sendable {
    case tokenizerProfileMismatch(
        expected: LocalLlamaTokenizerProfile,
        actual: LocalLlamaTokenizerProfile
    )
    case emptyCandidate
    case currentWordTypoGuardRejected
    case midWordHealingRejected

    public var errorDescription: String? {
        switch self {
        case .tokenizerProfileMismatch:
            return "Constrained local completion tokenizer profile does not match this model."
        case .emptyCandidate:
            return "Constrained local completion produced no usable candidate."
        case .currentWordTypoGuardRejected:
            return "Constrained local completion rejected a likely current-word typo."
        case .midWordHealingRejected:
            return "Constrained local completion rejected an unsafe mid-word seam."
        }
    }
}

public struct ConstrainedLocalCompletionProvider: MultiplePersonalizationContextAwareCompletionProvider, PromptCacheReportingCompletionProvider, RuntimeSwitchPreparingCompletionProvider {
    public let configuration: ConstrainedLocalCompletionConfiguration
    public let requestFactory: CompletionRequestFactory
    private let runtime: LocalLlamaRuntimeCore
    private let promptCacheHintTracker: LlamaPromptCacheHintTracker
    private let frozenSideContextStore: FrozenPromptSideContextStore
    private let runtimeStatusRecorder: LocalLlamaRuntimeStatusRecorder?
    private let multiBranchMetricsRecorder: AutoCompMultiBranchMetricsRecorder?

    public init(
        configuration: ConstrainedLocalCompletionConfiguration,
        requestFactory: CompletionRequestFactory = CompletionRequestFactory(),
        runtime: LocalLlamaRuntimeCore = LocalLlamaRuntimeCore(),
        promptCacheHintTracker: LlamaPromptCacheHintTracker = LlamaPromptCacheHintTracker(),
        frozenSideContextStore: FrozenPromptSideContextStore = FrozenPromptSideContextStore(),
        runtimeStatusRecorder: LocalLlamaRuntimeStatusRecorder? = nil,
        multiBranchMetricsRecorder: AutoCompMultiBranchMetricsRecorder? = nil
    ) {
        self.configuration = configuration
        self.requestFactory = requestFactory
        self.runtime = runtime
        self.promptCacheHintTracker = promptCacheHintTracker
        self.frozenSideContextStore = frozenSideContextStore
        self.runtimeStatusRecorder = runtimeStatusRecorder
        self.multiBranchMetricsRecorder = multiBranchMetricsRecorder
    }

    public init(
        localConfiguration: LocalLlamaConfiguration,
        requestFactory: CompletionRequestFactory = CompletionRequestFactory(),
        runtime: LocalLlamaRuntimeCore = LocalLlamaRuntimeCore(),
        promptCacheHintTracker: LlamaPromptCacheHintTracker = LlamaPromptCacheHintTracker(),
        frozenSideContextStore: FrozenPromptSideContextStore = FrozenPromptSideContextStore(),
        runtimeStatusRecorder: LocalLlamaRuntimeStatusRecorder? = nil,
        multiBranchMetricsRecorder: AutoCompMultiBranchMetricsRecorder? = nil
    ) {
        self.init(
            configuration: ConstrainedLocalCompletionConfiguration(localConfiguration: localConfiguration),
            requestFactory: requestFactory,
            runtime: runtime,
            promptCacheHintTracker: promptCacheHintTracker,
            frozenSideContextStore: frozenSideContextStore,
            runtimeStatusRecorder: runtimeStatusRecorder,
            multiBranchMetricsRecorder: multiBranchMetricsRecorder
        )
    }

    public func complete(
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?,
        clipboardContext: ClipboardContextSnapshot?,
        personalizationSamples: [PersonalizationSample]
    ) async throws -> Suggestion {
        let suggestions = try await complete(
            context: context,
            privacySettings: privacySettings,
            visualContext: visualContext,
            clipboardContext: clipboardContext,
            personalizationSamples: personalizationSamples,
            options: CompletionOptions()
        )
        guard let suggestion = suggestions.first else {
            throw ConstrainedLocalCompletionError.emptyCandidate
        }
        return suggestion
    }

    public func complete(
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?,
        clipboardContext: ClipboardContextSnapshot?,
        personalizationSamples: [PersonalizationSample],
        options: CompletionOptions
    ) async throws -> [Suggestion] {
        let startedAt = ContinuousClock.now
        let localConfiguration = configuration.localConfiguration
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
        let midWordPlan: MidWordRegenerationPlan?
        if configuration.midWordHealingEnabled,
           case .plan(let plan) = MidWordRegenerationPlanner().decision(
                textBeforeCursor: context.textBeforeCursor,
                textAfterCursor: context.textAfterCursor
           ) {
            midWordPlan = plan
        } else {
            midWordPlan = nil
        }
        let requestContext = midWordPlan.map { stableContext.copy(textBeforeCursor: $0.head) } ?? stableContext
        let completionRequest = requestFactory.makeRequest(
            for: requestContext,
            configuration: RemoteCompletionConfiguration(
                baseURL: "local://constrained-in-process",
                apiKey: "local",
                model: localConfiguration.modelName,
                maxTokens: localConfiguration.maxTokens,
                stopSequences: localConfiguration.stopSequences
            ),
            privacySettings: privacySettings,
            visualContext: frozen.context.visualContext,
            clipboardContext: frozen.context.clipboardContext,
            personalizationSamples: frozen.context.personalizationSamples
        )

        let actualTokenizerProfile = try await loadRuntimeAndValidateTokenizerProfile()
        let resetReason = await promptCacheHintTracker.observe(
            context: context,
            configuration: localConfiguration,
            request: completionRequest,
            tokenizerSignature: actualTokenizerProfile.cacheSignature,
            decoderCapabilities: configuration.multiBranchDecoderEnabled
                ? "constrained-multibranch-v1"
                : "constrained-v1",
            privacySettings: privacySettings,
            forcedResetReason: frozen.resetReason
        )
        if resetReason != nil { await runtime.resetPromptCache() }

        var usedMultiBranchDecoder = false
        var rawTexts: [String]
        if configuration.multiBranchDecoderEnabled {
            do {
                rawTexts = try await decodeMultiple(
                    request: completionRequest,
                    requiredPrefix: midWordPlan?.requiredPrefix ?? "",
                    suggestionCount: options.suggestionCount
                )
                usedMultiBranchDecoder = true
            } catch is CancellationError {
                var metrics = AutoCompMultiBranchMetrics()
                metrics.cancellationCount = 1
                await multiBranchMetricsRecorder?(metrics)
                throw CancellationError()
            } catch {
                await recordFallback(reason: fallbackReason(for: error))
                rawTexts = [try await runtime.generateCompletion(for: completionRequest)]
            }
        } else {
            rawTexts = [try await runtime.generateCompletion(for: completionRequest)]
        }

        if !usedMultiBranchDecoder, let rawText = rawTexts.first {
            return [try makeSuggestion(
                rawText: rawText,
                context: context,
                request: completionRequest,
                midWordPlan: midWordPlan,
                startedAt: startedAt
            )]
        }

        var suggestions: [Suggestion] = []
        var seen = Set<String>()
        for rawText in rawTexts {
            do {
                let suggestion = try makeSuggestion(
                    rawText: rawText,
                    context: context,
                    request: completionRequest,
                    midWordPlan: midWordPlan,
                    startedAt: startedAt
                )
                if seen.insert(suggestion.visibleText).inserted {
                    suggestions.append(suggestion)
                }
            } catch {
                continue
            }
            if suggestions.count == options.suggestionCount { break }
        }
        if suggestions.isEmpty, usedMultiBranchDecoder {
            await recordFallback(reason: .candidatesRejected, wrongShowCount: rawTexts.count)
            let conventional = try await runtime.generateCompletion(for: completionRequest)
            suggestions = [try makeSuggestion(
                rawText: conventional,
                context: context,
                request: completionRequest,
                midWordPlan: midWordPlan,
                startedAt: startedAt
            )]
        }
        guard !suggestions.isEmpty else { throw ConstrainedLocalCompletionError.emptyCandidate }
        return suggestions
    }

    private func makeSuggestion(
        rawText: String,
        context: TextContext,
        request completionRequest: CompletionRequest,
        midWordPlan: MidWordRegenerationPlan?,
        startedAt: ContinuousClock.Instant
    ) throws -> Suggestion {
        let normalizedText = SuggestionTextNormalizer.normalize(
            rawText: rawText,
            request: completionRequest
        )
        let healedText: String
        if let midWordPlan {
            guard case .publish(let value) = MidWordCandidateReconciler().reconcile(
                candidate: normalizedText,
                plan: midWordPlan
            ) else {
                throw ConstrainedLocalCompletionError.midWordHealingRejected
            }
            healedText = value
        } else {
            healedText = normalizedText
        }
        let constrainedText = try constrain(
            healedText,
            request: completionRequest
        )

        return Suggestion(
            baseContextID: context.id,
            visibleText: constrainedText,
            rawText: rawText,
            latencyMs: startedAt.duration(to: .now).milliseconds
        )
    }

    private func decodeMultiple(
        request: CompletionRequest,
        requiredPrefix: String,
        suggestionCount: Int
    ) async throws -> [String] {
        guard let tokenProfilePath = configuration.tokenProfilePath,
              !tokenProfilePath.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MultiBranchSetupError.profileMissing
        }
        let profileURL = URL(fileURLWithPath: tokenProfilePath)
        guard FileManager.default.fileExists(atPath: profileURL.path) else {
            throw MultiBranchSetupError.profileMissing
        }
        let loadStartedAt = ContinuousClock.now
        let profile = try AutoCompTokenProfileCodec.load(from: profileURL)
        let attributes = try? FileManager.default.attributesOfItem(atPath: profileURL.path)
        let profileBytes = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        let actual = try await runtime.experimentalTokenProfile(modelFamily: profile.modelFamily)
        try AutoCompTokenProfileCodec.validate(
            profile,
            tokenizerDigest: actual.tokenizerDigest,
            vocabularySize: actual.vocabularySize
        )
        var policy = configuration.multiBranchPolicy
        policy.maximumTokens = min(policy.maximumTokens, request.maxTokens)
        policy.candidateCount = max(1, suggestionCount)
        policy.stopSequences = request.stopSequences
        let decodeStartedAt = ContinuousClock.now
        var result = try await AutoCompMultiBranchDecoder().decode(
            prompt: request.prompt,
            requiredPrefix: requiredPrefix,
            profile: profile,
            policy: policy,
            runtime: runtime
        )
        result.metrics.profileLoadMilliseconds = Double(loadStartedAt.duration(to: decodeStartedAt).milliseconds)
        result.metrics.profileBytes = profileBytes
        result.metrics.decodeMilliseconds = Double(decodeStartedAt.duration(to: .now).milliseconds)
        await multiBranchMetricsRecorder?(result.metrics)
        return result.candidates.map(\.text)
    }

    private func fallbackReason(for error: Error) -> AutoCompMultiBranchFallbackReason {
        if error is MultiBranchSetupError { return .profileMissing }
        if let profileError = error as? AutoCompTokenProfileError {
            switch profileError {
            case .tokenizerDigestMismatch, .vocabularySizeMismatch:
                return .tokenizerMismatch
            default:
                return .profileInvalid
            }
        }
        if let localError = error as? LocalLlamaError, localError == .runtimeUnavailable {
            return .runtimeUnsupported
        }
        return .decoderFailed
    }

    private func recordFallback(
        reason: AutoCompMultiBranchFallbackReason,
        wrongShowCount: Int = 0
    ) async {
        var metrics = AutoCompMultiBranchMetrics()
        metrics.fallbackReason = reason
        metrics.wrongShowCount = max(0, wrongShowCount)
        await multiBranchMetricsRecorder?(metrics)
    }

    private enum MultiBranchSetupError: Error {
        case profileMissing
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

    private func loadRuntimeAndValidateTokenizerProfile() async throws -> LocalLlamaTokenizerProfile {
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
            return actualProfile
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
