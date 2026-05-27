import Foundation

public enum BackendConnectionState: String, Equatable, Sendable {
    case connected = "Connected"
    case disconnected = "Disconnected"
    case paused = "Paused"
}

public struct BackendStatusSummary: Equatable, Sendable {
    public static let connected = BackendStatusSummary(state: .connected)

    public let state: BackendConnectionState
    public let issue: BackendConnectivityIssue?
    public let suppressUntil: Date?

    public init(
        state: BackendConnectionState,
        issue: BackendConnectivityIssue? = nil,
        suppressUntil: Date? = nil
    ) {
        self.state = state
        self.issue = issue
        self.suppressUntil = suppressUntil
    }

    public var title: String {
        state.rawValue
    }

    public var menuTitle: String {
        menuTitle(at: Date())
    }

    public func menuTitle(at now: Date) -> String {
        let reason = issue?.statusReason

        switch state {
        case .connected:
            return title
        case .disconnected:
            guard let reason else {
                return title
            }
            return "\(title) (\(reason))"
        case .paused:
            guard let reason else {
                return title
            }
            if let seconds = remainingSuppressionSeconds(at: now) {
                return "\(title) (\(reason), \(seconds)s)"
            }
            return "\(title) (\(reason))"
        }
    }

    public func statusMessage(at now: Date = Date()) -> String {
        menuTitle(at: now)
    }

    public func remainingSuppressionSeconds(at now: Date = Date()) -> Int? {
        guard state == .paused,
              let suppressUntil,
              suppressUntil > now else {
            return nil
        }

        return max(1, Int(ceil(suppressUntil.timeIntervalSince(now))))
    }
}

public struct RemoteCircuitBreaker: Sendable {
    public private(set) var consecutiveFailures: Int
    public private(set) var suppressUntil: Date?
    public private(set) var lastIssue: BackendConnectivityIssue?

    public let failureThreshold: Int
    public let suppressionInterval: TimeInterval

    public init(
        failureThreshold: Int = 3,
        suppressionInterval: TimeInterval = 30,
        consecutiveFailures: Int = 0,
        suppressUntil: Date? = nil,
        lastIssue: BackendConnectivityIssue? = nil
    ) {
        self.failureThreshold = max(1, failureThreshold)
        self.suppressionInterval = suppressionInterval
        self.consecutiveFailures = max(0, consecutiveFailures)
        self.suppressUntil = suppressUntil
        self.lastIssue = lastIssue
    }

    public func allowsAutomaticTrigger(at now: Date = Date()) -> Bool {
        suppressionSummary(at: now) == nil
    }

    public func suppressionSummary(at now: Date = Date()) -> BackendStatusSummary? {
        guard let suppressUntil,
              suppressUntil > now else {
            return nil
        }

        return BackendStatusSummary(
            state: .paused,
            issue: lastIssue,
            suppressUntil: suppressUntil
        )
    }

    public func status(at now: Date = Date()) -> BackendStatusSummary {
        if let suppression = suppressionSummary(at: now) {
            return suppression
        }

        if let lastIssue {
            return BackendStatusSummary(state: .disconnected, issue: lastIssue)
        }

        return .connected
    }

    @discardableResult
    public mutating func recordSuccess(at now: Date = Date()) -> BackendStatusSummary {
        consecutiveFailures = 0
        suppressUntil = nil
        lastIssue = nil
        return status(at: now)
    }

    @discardableResult
    public mutating func recordFailure(_ error: Error, at now: Date = Date()) -> BackendStatusSummary {
        guard let issue = Self.issue(from: error) else {
            return status(at: now)
        }

        return recordFailure(issue: issue, at: now)
    }

    @discardableResult
    public mutating func recordFailure(
        issue: BackendConnectivityIssue,
        at now: Date = Date()
    ) -> BackendStatusSummary {
        lastIssue = issue

        guard issue.isTransientBackendFailure else {
            consecutiveFailures = 0
            if suppressionSummary(at: now) == nil {
                suppressUntil = nil
            }
            return status(at: now)
        }

        consecutiveFailures += 1
        if consecutiveFailures >= failureThreshold {
            suppressUntil = now.addingTimeInterval(suppressionInterval)
        }

        return status(at: now)
    }

    public static func issue(from error: Error) -> BackendConnectivityIssue? {
        guard let remoteError = error as? RemoteCompletionError else {
            return nil
        }
        return remoteError.issue
    }
}

public struct BackendHealthMonitor: Sendable {
    public private(set) var circuitBreaker: RemoteCircuitBreaker
    public private(set) var summary: BackendStatusSummary

    public init(circuitBreaker: RemoteCircuitBreaker = RemoteCircuitBreaker()) {
        self.circuitBreaker = circuitBreaker
        self.summary = circuitBreaker.status()
    }

    public func allowsAutomaticTrigger(at now: Date = Date()) -> Bool {
        circuitBreaker.allowsAutomaticTrigger(at: now)
    }

    public func suppressionSummary(at now: Date = Date()) -> BackendStatusSummary? {
        circuitBreaker.suppressionSummary(at: now)
    }

    @discardableResult
    public mutating func refresh(at now: Date = Date()) -> BackendStatusSummary {
        summary = circuitBreaker.status(at: now)
        return summary
    }

    @discardableResult
    public mutating func recordSuccess(at now: Date = Date()) -> BackendStatusSummary {
        summary = circuitBreaker.recordSuccess(at: now)
        return summary
    }

    @discardableResult
    public mutating func recordFailure(_ error: Error, at now: Date = Date()) -> BackendStatusSummary? {
        guard RemoteCircuitBreaker.issue(from: error) != nil else {
            return nil
        }

        summary = circuitBreaker.recordFailure(error, at: now)
        return summary
    }

    @discardableResult
    public mutating func recordFailure(
        issue: BackendConnectivityIssue,
        at now: Date = Date()
    ) -> BackendStatusSummary {
        summary = circuitBreaker.recordFailure(issue: issue, at: now)
        return summary
    }

    @discardableResult
    public mutating func reset(at now: Date = Date()) -> BackendStatusSummary {
        circuitBreaker = RemoteCircuitBreaker(
            failureThreshold: circuitBreaker.failureThreshold,
            suppressionInterval: circuitBreaker.suppressionInterval
        )
        summary = circuitBreaker.status(at: now)
        return summary
    }
}
