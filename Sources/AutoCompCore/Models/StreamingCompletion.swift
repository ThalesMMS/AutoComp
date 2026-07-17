import Foundation

public struct StreamingCompletionCapability: Equatable, Sendable {
    public let route: CompletionEngineKind

    public init(route: CompletionEngineKind) {
        self.route = route
    }
}

public struct StreamingCompletionConfiguration: Equatable, Sendable {
    public var enabledRoutes: Set<CompletionEngineKind>

    public init(enabledRoutes: Set<CompletionEngineKind> = []) {
        self.enabledRoutes = enabledRoutes
    }

    public static let disabled = StreamingCompletionConfiguration()

    public func enables(_ capability: StreamingCompletionCapability?) -> Bool {
        guard let capability else { return false }
        return enabledRoutes.contains(capability.route)
    }
}

public struct StreamingCompletionMetadata: Equatable, Sendable {
    public let traceContext: CompletionTraceContext
    public let workID: Int
    public let providerAttempt: Int
    public let requestedRoute: CompletionEngineKind

    public init(
        traceContext: CompletionTraceContext,
        workID: Int,
        providerAttempt: Int = 0,
        requestedRoute: CompletionEngineKind
    ) {
        self.traceContext = traceContext
        self.workID = workID
        self.providerAttempt = max(0, providerAttempt)
        self.requestedRoute = requestedRoute
    }
}

public enum CompletionPartialPhase: String, Codable, Equatable, Sendable {
    case partial
    case final
}

public struct CompletionPartial: Equatable, Sendable {
    public let metadata: StreamingCompletionMetadata
    public let accumulatedText: String
    public let rawAccumulatedText: String?
    public let providerSequence: Int
    public let route: CompletionRoute
    public let phase: CompletionPartialPhase
    public let latencyMs: Int

    public init(
        metadata: StreamingCompletionMetadata,
        accumulatedText: String,
        rawAccumulatedText: String? = nil,
        providerSequence: Int,
        route: CompletionRoute,
        phase: CompletionPartialPhase,
        latencyMs: Int
    ) {
        self.metadata = metadata
        self.accumulatedText = accumulatedText
        self.rawAccumulatedText = rawAccumulatedText
        self.providerSequence = max(0, providerSequence)
        self.route = route
        self.phase = phase
        self.latencyMs = max(0, latencyMs)
    }

    public var isFinal: Bool { phase == .final }
}

public protocol StreamingCompletionProvider: CompletionProvider {
    var streamingCompletionCapability: StreamingCompletionCapability? { get }

    func streamCompletion(
        request: ProviderInvocation.Request,
        metadata: StreamingCompletionMetadata
    ) -> AsyncThrowingStream<CompletionPartial, Error>
}

public struct SuggestionStreamingMetadata: Equatable, Sendable {
    public let traceID: CompletionTraceID
    public let workID: Int
    public let providerSequence: Int
    public let isFinal: Bool

    public init(
        traceID: CompletionTraceID,
        workID: Int,
        providerSequence: Int,
        isFinal: Bool
    ) {
        self.traceID = traceID
        self.workID = workID
        self.providerSequence = max(0, providerSequence)
        self.isFinal = isFinal
    }
}
