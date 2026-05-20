import Foundation

public struct VisualContextSnapshot: Codable, Equatable, Sendable {
    public let summary: String
    public let captureSources: Set<TextCaptureSource>
    public let createdAt: Date

    public init(
        summary: String,
        captureSources: Set<TextCaptureSource> = [.screenOCR],
        createdAt: Date = Date()
    ) {
        self.summary = summary.trimmingCharacters(in: .whitespacesAndNewlines)
        self.captureSources = captureSources
        self.createdAt = createdAt
    }

    public var isEmpty: Bool {
        summary.isEmpty
    }
}

public protocol VisualContextProvider: Sendable {
    func currentVisualContext() async -> VisualContextSnapshot?
}
