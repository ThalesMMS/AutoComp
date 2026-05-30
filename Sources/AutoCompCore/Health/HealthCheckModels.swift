import Foundation

public enum HealthStatus: String, Codable, Sendable, CaseIterable {
    case ok
    case warn
    case fail
    case unknown
}

public struct HealthRemediationAction: Identifiable, Codable, Sendable, Hashable {
    public enum Kind: String, Codable, Sendable {
        case openURL
        case openSystemSettings
        case openInAppSettings
        case retry
        case showInstructions
    }

    public let id: String
    public let title: String
    public let kind: Kind
    public let url: URL?
    public let payload: String?

    public init(
        id: String,
        title: String,
        kind: Kind,
        url: URL? = nil,
        payload: String? = nil
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.url = url
        self.payload = payload
    }
}

public struct HealthCheck: Identifiable, Codable, Sendable {
    public let id: String
    public let title: String
    public let status: HealthStatus
    public let summary: String
    public let details: String?
    public let actions: [HealthRemediationAction]

    public init(
        id: String,
        title: String,
        status: HealthStatus,
        summary: String,
        details: String? = nil,
        actions: [HealthRemediationAction] = []
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.summary = summary
        self.details = details
        self.actions = actions
    }

    public var isEmpty: Bool {
        summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && (details?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
            && actions.isEmpty
    }
}

public struct HealthSnapshot: Codable, Sendable {
    public let generatedAt: Date
    public let checks: [HealthCheck]

    public init(generatedAt: Date = Date(), checks: [HealthCheck]) {
        self.generatedAt = generatedAt
        self.checks = checks
    }
}

@MainActor
public protocol HealthSnapshotServicing: AnyObject {
    var snapshot: HealthSnapshot { get }

    func refresh()
}
