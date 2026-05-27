import Foundation

public struct LlamaPromptCacheStats: Equatable, Sendable {
    public let hits: UInt64
    public let misses: UInt64
    public let resets: UInt64
    public let retainedPromptTokens: Int
    public let contextTokens: UInt32

    public init(
        hits: UInt64,
        misses: UInt64,
        resets: UInt64,
        retainedPromptTokens: Int,
        contextTokens: UInt32
    ) {
        self.hits = hits
        self.misses = misses
        self.resets = resets
        self.retainedPromptTokens = retainedPromptTokens
        self.contextTokens = contextTokens
    }

    public static let empty = LlamaPromptCacheStats(
        hits: 0,
        misses: 0,
        resets: 0,
        retainedPromptTokens: 0,
        contextTokens: 0
    )
}

public enum LlamaPromptCacheResetReason: String, Equatable, Sendable {
    case fieldChanged
    case modelChanged
    case configurationChanged
}

public struct LlamaPromptCache: Equatable, Sendable {
    public let field: Field
    public let modelPath: String
    public let modelName: String
    public let maxTokens: Int
    public let maxRAMBytes: UInt64

    public init(context: TextContext, configuration: LocalLlamaConfiguration) {
        self.field = Field(context: context)
        self.modelPath = configuration.modelPath
        self.modelName = configuration.modelName
        self.maxTokens = configuration.maxTokens
        self.maxRAMBytes = configuration.maxRAMBytes
    }

    public func resetReason(comparedTo previous: LlamaPromptCache) -> LlamaPromptCacheResetReason? {
        guard field == previous.field else {
            return .fieldChanged
        }
        guard modelPath == previous.modelPath,
              modelName == previous.modelName else {
            return .modelChanged
        }
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
    }
}

public actor LlamaPromptCacheHintTracker {
    private var current: LlamaPromptCache?
    private var lastResetReason: LlamaPromptCacheResetReason?

    public init() {}

    public func observe(
        context: TextContext,
        configuration: LocalLlamaConfiguration
    ) -> LlamaPromptCacheResetReason? {
        let next = LlamaPromptCache(context: context, configuration: configuration)
        defer {
            current = next
        }

        guard let current else {
            lastResetReason = nil
            return nil
        }

        let reason = next.resetReason(comparedTo: current)
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
