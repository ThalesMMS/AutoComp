import Foundation

public struct ClipboardContextSnapshot: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Equatable, Sendable {
        case included
        case omittedBeforeBaseline
        case omittedExpired
        case omittedEmpty
        case omittedNotRelevant
    }

    public let summary: String
    public let status: Status
    public let captureSources: Set<TextCaptureSource>
    public let createdAt: Date

    public init(
        summary: String,
        status: Status,
        captureSources: Set<TextCaptureSource> = [],
        createdAt: Date = Date()
    ) {
        self.summary = summary
        self.status = status
        self.captureSources = captureSources
        self.createdAt = createdAt
    }

    public var isIncluded: Bool {
        status == .included && !summary.isEmpty
    }

    public var promptPreview: String {
        if isIncluded {
            return summary
        }
        return "[clipboard omitted: \(status.promptReason)]"
    }
}

public extension ClipboardContextSnapshot.Status {
    var promptReason: String {
        switch self {
        case .included:
            return "included"
        case .omittedBeforeBaseline:
            return "before app start"
        case .omittedExpired:
            return "expired"
        case .omittedEmpty:
            return "empty"
        case .omittedNotRelevant:
            return "not relevant"
        }
    }
}
