import Foundation

enum AsyncTimeoutResult<Value: Sendable>: Sendable {
    case completed(Value)
    case timedOut
}

enum CallbackTimeoutResult<Value: Sendable>: Sendable {
    case completed(Value?)
    case timedOut
}

enum AsyncTimeout {
    static func run<Value: Sendable>(
        seconds: TimeInterval,
        onTimeout: @escaping @Sendable () -> Void = {},
        operation: @escaping @Sendable () async -> Value
    ) async -> AsyncTimeoutResult<Value> {
        let timeout = max(0.01, seconds)
        return await withCheckedContinuation { continuation in
            let gate = OneShotContinuation(continuation)
            let task = Task {
                let value = await operation()
                gate.resume(.completed(value))
            }

            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                if gate.resume(.timedOut) {
                    task.cancel()
                    onTimeout()
                }
            }
        }
    }

    static func waitForCallback<Value: Sendable>(
        seconds: TimeInterval,
        onTimeout: @escaping @Sendable () -> Void = {},
        start: (_ complete: @escaping @Sendable (Value?) -> Void) -> Void
    ) async -> CallbackTimeoutResult<Value> {
        let timeout = max(0.01, seconds)
        return await withCheckedContinuation { continuation in
            let gate = OneShotContinuation(continuation)
            start { value in
                gate.resume(.completed(value))
            }

            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                if gate.resume(.timedOut) {
                    onTimeout()
                }
            }
        }
    }
}

private final class OneShotContinuation<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Never>?

    init(_ continuation: CheckedContinuation<Value, Never>) {
        self.continuation = continuation
    }

    @discardableResult
    func resume(_ value: sending Value) -> Bool {
        let continuationToResume: CheckedContinuation<Value, Never>? = lock.withLock {
            guard let continuation else {
                return nil
            }
            self.continuation = nil
            return continuation
        }
        guard let continuationToResume else {
            return false
        }
        continuationToResume.resume(returning: value)
        return true
    }
}
