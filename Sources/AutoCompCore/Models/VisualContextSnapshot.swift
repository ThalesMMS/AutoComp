import Foundation

public struct VisualContextSnapshot: Codable, Equatable, Sendable {
    public let summary: String
    public let captureSources: Set<TextCaptureSource>
    public let createdAt: Date
    public let stableFieldIdentity: StableFieldIdentity?

    public init(
        summary: String,
        captureSources: Set<TextCaptureSource> = [.screenOCR],
        createdAt: Date = Date(),
        stableFieldIdentity: StableFieldIdentity? = nil
    ) {
        self.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        self.captureSources = captureSources
        self.createdAt = createdAt
        self.stableFieldIdentity = stableFieldIdentity
    }

    public var isEmpty: Bool {
        summary.isEmpty
    }
}

public enum VisualContextSessionState: String, Codable, CaseIterable, Sendable {
    case idle
    case capturing
    case ocr
    case summarizing
    case ready
    case failed
    case expired
}

public struct VisualContextSession: Codable, Equatable, Sendable {
    public let identity: StableFieldIdentity
    public let state: VisualContextSessionState
    public let snapshot: VisualContextSnapshot?
    public let statusMessage: String?
    public let updatedAt: Date

    public init(
        identity: StableFieldIdentity,
        state: VisualContextSessionState,
        snapshot: VisualContextSnapshot? = nil,
        statusMessage: String? = nil,
        updatedAt: Date = Date()
    ) {
        self.identity = identity
        self.state = state
        self.snapshot = snapshot
        self.statusMessage = statusMessage
        self.updatedAt = updatedAt
    }
}

public protocol VisualContextProvider: Sendable {
    func currentVisualContext() async -> VisualContextSnapshot?
}

public protocol VisualContextSessionClearing: Sendable {
    func clearVisualContextSession()
}

public protocol StableFieldVisualContextProvider: VisualContextProvider {
    func currentVisualContext(for stableFieldIdentity: StableFieldIdentity?) async -> VisualContextSnapshot?
}
