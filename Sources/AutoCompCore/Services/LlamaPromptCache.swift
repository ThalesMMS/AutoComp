import Foundation

public struct LocalPromptReuseMetrics: Equatable, Sendable {
    public let promptTokens: Int
    public let commonPrefixTokens: Int
    public let reusedTokens: Int
    public let prefillTokens: Int
    public let tokenizationMilliseconds: Double
    public let prefillMilliseconds: Double
    public let decodeMilliseconds: Double
    public let cacheRebuilds: UInt64

    public init(
        promptTokens: Int = 0,
        commonPrefixTokens: Int = 0,
        reusedTokens: Int = 0,
        prefillTokens: Int = 0,
        tokenizationMilliseconds: Double = 0,
        prefillMilliseconds: Double = 0,
        decodeMilliseconds: Double = 0,
        cacheRebuilds: UInt64 = 0
    ) {
        self.promptTokens = promptTokens
        self.commonPrefixTokens = commonPrefixTokens
        self.reusedTokens = reusedTokens
        self.prefillTokens = prefillTokens
        self.tokenizationMilliseconds = tokenizationMilliseconds
        self.prefillMilliseconds = prefillMilliseconds
        self.decodeMilliseconds = decodeMilliseconds
        self.cacheRebuilds = cacheRebuilds
    }

    public static let empty = LocalPromptReuseMetrics()
}

public struct LlamaPromptCacheStats: Equatable, Sendable {
    public let hits: UInt64
    public let misses: UInt64
    public let resets: UInt64
    public let retainedPromptTokens: Int
    public let contextTokens: UInt32
    public let reuse: LocalPromptReuseMetrics
    public let lastResetReason: LlamaPromptCacheResetReason?

    public init(
        hits: UInt64,
        misses: UInt64,
        resets: UInt64,
        retainedPromptTokens: Int,
        contextTokens: UInt32,
        reuse: LocalPromptReuseMetrics = .empty,
        lastResetReason: LlamaPromptCacheResetReason? = nil
    ) {
        self.hits = hits
        self.misses = misses
        self.resets = resets
        self.retainedPromptTokens = retainedPromptTokens
        self.contextTokens = contextTokens
        self.reuse = reuse
        self.lastResetReason = lastResetReason
    }

    public static let empty = LlamaPromptCacheStats(
        hits: 0,
        misses: 0,
        resets: 0,
        retainedPromptTokens: 0,
        contextTokens: 0
    )

    public func recording(resetReason: LlamaPromptCacheResetReason?) -> Self {
        Self(
            hits: hits,
            misses: misses,
            resets: resets,
            retainedPromptTokens: retainedPromptTokens,
            contextTokens: contextTokens,
            reuse: reuse,
            lastResetReason: resetReason
        )
    }
}

public enum LlamaPromptCacheResetReason: String, Equatable, Sendable {
    case coldStart
    case noCommonPrefix
    case fieldChanged
    case modelChanged
    case tokenizerChanged
    case requestModeChanged
    case rendererChanged
    case samplingChanged
    case stopPolicyChanged
    case decoderCapabilitiesChanged
    case privacyChanged
    case sideContextChanged
    case ttlExpired
    case runtimeInconsistency
    case contextSizeChanged
    case configurationChanged
}

public struct LlamaPromptCache: Equatable, Sendable {
    public let field: Field
    public let modelPath: String
    public let modelName: String
    public let maxTokens: Int
    public let maxRAMBytes: UInt64
    public let requestMode: CompletionRequestMode?
    public let rendererVersion: String
    public let temperature: Double?
    public let stopSequences: [String]
    public let tokenizerSignature: String?
    public let decoderCapabilities: String
    public let privacySettings: PrivacySettings?

    public init(
        context: TextContext,
        configuration: LocalLlamaConfiguration,
        request: CompletionRequest? = nil,
        tokenizerSignature: String? = nil,
        rendererVersion: String = PromptBuilder.localRendererVersion,
        decoderCapabilities: String = "conventional",
        privacySettings: PrivacySettings? = nil
    ) {
        self.field = Field(context: context)
        self.modelPath = configuration.modelPath
        self.modelName = configuration.modelName
        self.maxTokens = configuration.maxTokens
        self.maxRAMBytes = configuration.maxRAMBytes
        self.requestMode = request?.mode
        self.rendererVersion = rendererVersion
        self.temperature = request?.temperature
        self.stopSequences = request?.stopSequences ?? []
        self.tokenizerSignature = tokenizerSignature
        self.decoderCapabilities = decoderCapabilities
        self.privacySettings = privacySettings
    }

    public func resetReason(comparedTo previous: LlamaPromptCache) -> LlamaPromptCacheResetReason? {
        guard field == previous.field else {
            return .fieldChanged
        }
        guard modelPath == previous.modelPath,
              modelName == previous.modelName else {
            return .modelChanged
        }
        guard tokenizerSignature == previous.tokenizerSignature else { return .tokenizerChanged }
        guard requestMode == previous.requestMode else { return .requestModeChanged }
        guard rendererVersion == previous.rendererVersion else { return .rendererChanged }
        guard temperature == previous.temperature else { return .samplingChanged }
        guard stopSequences == previous.stopSequences else { return .stopPolicyChanged }
        guard decoderCapabilities == previous.decoderCapabilities else { return .decoderCapabilitiesChanged }
        guard privacySettings == previous.privacySettings else { return .privacyChanged }
        guard maxTokens == previous.maxTokens,
              maxRAMBytes == previous.maxRAMBytes else {
            return .configurationChanged
        }
        return nil
    }

    public struct Field: Equatable, Sendable {
        public let stableIdentity: StableFieldIdentity?
        public let bundleID: String
        public let processID: Int32
        public let domain: String?
        public let focusedElementID: String

        public init(context: TextContext) {
            self.stableIdentity = context.stableFieldIdentity
            self.bundleID = context.app.bundleID
            self.processID = context.app.processID
            self.domain = context.domain
            self.focusedElementID = context.focusedElementID
        }

        public static func == (lhs: Self, rhs: Self) -> Bool {
            guard lhs.bundleID == rhs.bundleID,
                  lhs.processID == rhs.processID,
                  lhs.domain == rhs.domain else { return false }
            switch (lhs.stableIdentity, rhs.stableIdentity) {
            case (.some(let lhsStable), .some(let rhsStable)):
                return lhsStable == rhsStable
            case (.none, .none):
                return lhs.focusedElementID == rhs.focusedElementID
            default:
                return false
            }
        }
    }
}

public actor LlamaPromptCacheHintTracker {
    private var current: LlamaPromptCache?
    private var lastResetReason: LlamaPromptCacheResetReason?

    public init() {}

    public func observe(
        context: TextContext,
        configuration: LocalLlamaConfiguration,
        request: CompletionRequest? = nil,
        tokenizerSignature: String? = nil,
        rendererVersion: String = PromptBuilder.localRendererVersion,
        decoderCapabilities: String = "conventional",
        privacySettings: PrivacySettings? = nil,
        forcedResetReason: LlamaPromptCacheResetReason? = nil
    ) -> LlamaPromptCacheResetReason? {
        let next = LlamaPromptCache(
            context: context,
            configuration: configuration,
            request: request,
            tokenizerSignature: tokenizerSignature,
            rendererVersion: rendererVersion,
            decoderCapabilities: decoderCapabilities,
            privacySettings: privacySettings
        )
        defer {
            current = next
        }

        guard let current else {
            lastResetReason = nil
            return nil
        }

        let reason = forcedResetReason ?? next.resetReason(comparedTo: current)
        lastResetReason = reason
        return reason
    }

    public func reset() {
        current = nil
        lastResetReason = nil
    }

    public func lastReason() -> LlamaPromptCacheResetReason? {
        lastResetReason
    }
}
