import Foundation

public struct LocalModelDiagnosticsReport: Equatable, Sendable {
    public enum Severity: String, Equatable, Sendable {
        case info
        case warning
        case error
    }

    public struct Finding: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let severity: Severity
        public let title: String
        public let details: String?
        public let remediation: String?

        public init(
            id: UUID = UUID(),
            severity: Severity,
            title: String,
            details: String? = nil,
            remediation: String? = nil
        ) {
            self.id = id
            self.severity = severity
            self.title = title
            self.details = details
            self.remediation = remediation
        }
    }

    public enum SectionKind: String, Equatable, Sendable {
        case ggufFile
        case modelArchitecture
        case runtimeLibraries
        case runtime
        case memory
        case memoryFit
        case suggestions
    }

    public struct Section: Equatable, Sendable, Identifiable {
        public let id: UUID
        public let kind: SectionKind
        public let title: String
        public var findings: [Finding]

        public init(
            id: UUID = UUID(),
            kind: SectionKind,
            title: String,
            findings: [Finding] = []
        ) {
            self.id = id
            self.kind = kind
            self.title = title
            self.findings = findings
        }

        public var worstSeverity: Severity? {
            findings.map(\.severity).max(by: { $0.rank < $1.rank })
        }
    }

    public let createdAt: Date
    public var sections: [Section]

    public init(createdAt: Date = Date(), sections: [Section]) {
        self.createdAt = createdAt
        self.sections = sections
    }

    public var allFindings: [Finding] {
        sections.flatMap(\.findings)
    }

    public var worstSeverity: Severity? {
        allFindings.map(\.severity).max(by: { $0.rank < $1.rank })
    }

    public var hasErrors: Bool {
        allFindings.contains(where: { $0.severity == .error })
    }

    public var hasWarnings: Bool {
        allFindings.contains(where: { $0.severity == .warning })
    }
}

private extension LocalModelDiagnosticsReport.Severity {
    var rank: Int {
        switch self {
        case .info:
            return 0
        case .warning:
            return 1
        case .error:
            return 2
        }
    }
}
