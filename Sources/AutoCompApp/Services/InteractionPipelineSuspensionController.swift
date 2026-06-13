import Foundation

enum InteractionPipelineSuspensionReason: String, CaseIterable, Sendable {
    case openPanel = "open-panel"
    case modelImport = "model-import"
    case settingsImport = "settings-import"
    case settingsExport = "settings-export"
    case shutdown
}

struct InteractionPipelineSuspensionToken: Hashable, Sendable {
    fileprivate let id: UUID
    let reason: InteractionPipelineSuspensionReason
}

final class InteractionPipelineSuspensionController: @unchecked Sendable {
    typealias StateChangeHandler = (_ isSuspended: Bool, _ activeReasons: Set<InteractionPipelineSuspensionReason>) -> Void

    private let lock = NSLock()
    private let logger = AutoCompLogger(category: "pipeline-suspension")
    private var activeTokens: [UUID: InteractionPipelineSuspensionReason] = [:]
    private var reasonCounts: [InteractionPipelineSuspensionReason: Int] = [:]
    private var stateChangeHandlers: [UUID: StateChangeHandler] = [:]

    var isSuspended: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !activeTokens.isEmpty
    }

    var activeReasons: Set<InteractionPipelineSuspensionReason> {
        lock.lock()
        defer { lock.unlock() }
        return Set(reasonCounts.keys)
    }

    var activeDepth: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeTokens.count
    }

    @discardableResult
    func suspend(reason: InteractionPipelineSuspensionReason) -> InteractionPipelineSuspensionToken {
        let token = InteractionPipelineSuspensionToken(id: UUID(), reason: reason)
        let notification = mutateState { state in
            let wasSuspended = !state.activeTokens.isEmpty
            state.activeTokens[token.id] = reason
            state.reasonCounts[reason, default: 0] += 1
            return !wasSuspended
        }
        log("suspend", reason: reason)
        notifyIfNeeded(notification)
        return token
    }

    func resume(_ token: InteractionPipelineSuspensionToken) {
        let notification = mutateState { state in
            guard let reason = state.activeTokens.removeValue(forKey: token.id) else {
                return false
            }

            let nextCount = max(0, (state.reasonCounts[reason] ?? 0) - 1)
            state.reasonCounts[reason] = nextCount == 0 ? nil : nextCount
            return state.activeTokens.isEmpty
        }
        log("resume", reason: token.reason)
        notifyIfNeeded(notification)
    }

    func resume(reason: InteractionPipelineSuspensionReason) {
        var didResume = false
        let notification = mutateState { state in
            guard let token = state.activeTokens.first(where: { $0.value == reason }) else {
                return false
            }

            state.activeTokens.removeValue(forKey: token.key)
            let nextCount = max(0, (state.reasonCounts[reason] ?? 0) - 1)
            state.reasonCounts[reason] = nextCount == 0 ? nil : nextCount
            didResume = true
            return state.activeTokens.isEmpty
        }

        guard didResume else {
            log("resume-ignored", reason: reason)
            return
        }

        log("resume", reason: reason)
        notifyIfNeeded(notification)
    }

    func withPipelineSuspended<T>(
        reason: InteractionPipelineSuspensionReason,
        operation: () throws -> T
    ) rethrows -> T {
        let token = suspend(reason: reason)
        defer { resume(token) }
        return try operation()
    }

    func withPipelineSuspended<T>(
        reason: InteractionPipelineSuspensionReason,
        operation: () async throws -> T
    ) async rethrows -> T {
        let token = suspend(reason: reason)
        defer { resume(token) }
        return try await operation()
    }

    @discardableResult
    func addStateChangeHandler(_ handler: @escaping StateChangeHandler) -> UUID {
        let id = UUID()
        let snapshot = lock.withLock {
            stateChangeHandlers[id] = handler
            return stateSnapshot()
        }
        handler(snapshot.isSuspended, snapshot.activeReasons)
        return id
    }

    func removeStateChangeHandler(_ id: UUID) {
        lock.withLock {
            stateChangeHandlers[id] = nil
        }
    }

    private func mutateState(
        _ mutation: (inout MutableState) -> Bool
    ) -> StateChangeNotification? {
        lock.lock()
        var state = MutableState(
            activeTokens: activeTokens,
            reasonCounts: reasonCounts,
            handlers: stateChangeHandlers
        )
        let shouldNotify = mutation(&state)
        activeTokens = state.activeTokens
        reasonCounts = state.reasonCounts
        stateChangeHandlers = state.handlers
        let snapshot = stateSnapshot()
        lock.unlock()

        guard shouldNotify else {
            return nil
        }
        return StateChangeNotification(snapshot: snapshot)
    }

    private func notifyIfNeeded(_ notification: StateChangeNotification?) {
        guard let notification else {
            return
        }

        for handler in notification.snapshot.handlers.values {
            handler(notification.snapshot.isSuspended, notification.snapshot.activeReasons)
        }
    }

    private func stateSnapshot() -> StateSnapshot {
        StateSnapshot(
            isSuspended: !activeTokens.isEmpty,
            activeReasons: Set(reasonCounts.keys),
            depth: activeTokens.count,
            handlers: stateChangeHandlers
        )
    }

    private func log(_ action: String, reason: InteractionPipelineSuspensionReason) {
        let snapshot = lock.withLock {
            stateSnapshot()
        }
        let message = "pipeline-suspension action=\(action) reason=\(reason.rawValue) active=\(snapshot.isSuspended) depth=\(snapshot.depth) reasons=\(snapshot.activeReasons.debugSummary)"
        GeometryDebug.log(message)
        logger.info(message)
    }
}

private struct MutableState {
    var activeTokens: [UUID: InteractionPipelineSuspensionReason]
    var reasonCounts: [InteractionPipelineSuspensionReason: Int]
    var handlers: [UUID: InteractionPipelineSuspensionController.StateChangeHandler]
}

private struct StateSnapshot {
    let isSuspended: Bool
    let activeReasons: Set<InteractionPipelineSuspensionReason>
    let depth: Int
    let handlers: [UUID: InteractionPipelineSuspensionController.StateChangeHandler]
}

private struct StateChangeNotification {
    let snapshot: StateSnapshot
}

private extension Set where Element == InteractionPipelineSuspensionReason {
    var debugSummary: String {
        map(\.rawValue).sorted().joined(separator: ",")
    }
}
