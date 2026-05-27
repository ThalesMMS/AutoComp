import Foundation

public struct CompletionRoute: Codable, Equatable, Sendable {
    public var requestedKind: CompletionEngineKind
    public var deliveredKind: CompletionEngineKind
    public var fallbackErrorDescription: String?

    public init(
        requestedKind: CompletionEngineKind,
        deliveredKind: CompletionEngineKind,
        fallbackErrorDescription: String? = nil
    ) {
        self.requestedKind = requestedKind
        self.deliveredKind = deliveredKind
        self.fallbackErrorDescription = fallbackErrorDescription
    }

    public var usedFallback: Bool {
        requestedKind != deliveredKind
    }
}

public struct CompletionRoutingPolicy: Equatable, Sendable {
    public var activeKind: CompletionEngineKind
    public var fallbackKind: CompletionEngineKind?

    public init(activeKind: CompletionEngineKind, fallbackKind: CompletionEngineKind?) {
        self.activeKind = activeKind
        self.fallbackKind = fallbackKind
    }
}

public protocol CompletionRoutingProviding {
    var routingPolicy: CompletionRoutingPolicy { get }
}
