import AutoCompCore
import XCTest

final class BackendHealthMonitorTests: XCTestCase {
    func testTransientFailuresPauseAutomaticTriggersAndSuccessResets() throws {
        let now = Date(timeIntervalSince1970: 100)
        var monitor = BackendHealthMonitor(
            circuitBreaker: RemoteCircuitBreaker(
                failureThreshold: 3,
                suppressionInterval: 30
            )
        )

        XCTAssertEqual(monitor.summary.state, .connected)
        XCTAssertTrue(monitor.allowsAutomaticTrigger(at: now))

        var summary = try XCTUnwrap(monitor.recordFailure(
            RemoteCompletionError.connectivity(.timeout),
            at: now
        ))
        XCTAssertEqual(summary.state, .disconnected)
        XCTAssertTrue(monitor.allowsAutomaticTrigger(at: now))

        summary = try XCTUnwrap(monitor.recordFailure(
            RemoteCompletionError.connectivity(.offline),
            at: now.addingTimeInterval(1)
        ))
        XCTAssertEqual(summary.state, .disconnected)
        XCTAssertTrue(monitor.allowsAutomaticTrigger(at: now.addingTimeInterval(1)))

        summary = try XCTUnwrap(monitor.recordFailure(
            RemoteCompletionError.badStatus(503, ""),
            at: now.addingTimeInterval(2)
        ))
        XCTAssertEqual(summary.state, .paused)
        XCTAssertEqual(summary.issue, .httpStatus(503))
        XCTAssertEqual(summary.remainingSuppressionSeconds(at: now.addingTimeInterval(2)), 30)
        XCTAssertFalse(monitor.allowsAutomaticTrigger(at: now.addingTimeInterval(3)))

        XCTAssertEqual(monitor.refresh(at: now.addingTimeInterval(33)).state, .disconnected)

        summary = monitor.recordSuccess(at: now.addingTimeInterval(34))
        XCTAssertEqual(summary.state, .connected)
        XCTAssertEqual(monitor.circuitBreaker.consecutiveFailures, 0)
        XCTAssertTrue(monitor.allowsAutomaticTrigger(at: now.addingTimeInterval(34)))
    }

    func testConfigurationFailuresDoNotOpenBreaker() throws {
        let now = Date(timeIntervalSince1970: 100)
        var monitor = BackendHealthMonitor(
            circuitBreaker: RemoteCircuitBreaker(
                failureThreshold: 3,
                suppressionInterval: 30
            )
        )

        for offset in 0..<3 {
            _ = try XCTUnwrap(monitor.recordFailure(
                RemoteCompletionError.badStatus(401, ""),
                at: now.addingTimeInterval(Double(offset))
            ))
        }

        XCTAssertEqual(monitor.summary.state, .disconnected)
        XCTAssertEqual(monitor.summary.issue, .unauthorized)
        XCTAssertEqual(monitor.circuitBreaker.consecutiveFailures, 0)
        XCTAssertNil(monitor.circuitBreaker.suppressUntil)
        XCTAssertTrue(monitor.allowsAutomaticTrigger(at: now.addingTimeInterval(3)))
    }

    func testNonTransientFailureDuringSuppressionDoesNotClearActiveBackoff() throws {
        let now = Date(timeIntervalSince1970: 100)
        var monitor = BackendHealthMonitor(
            circuitBreaker: RemoteCircuitBreaker(
                failureThreshold: 3,
                suppressionInterval: 30
            )
        )

        _ = try XCTUnwrap(monitor.recordFailure(
            RemoteCompletionError.connectivity(.timeout),
            at: now
        ))
        _ = try XCTUnwrap(monitor.recordFailure(
            RemoteCompletionError.connectivity(.offline),
            at: now.addingTimeInterval(1)
        ))
        let paused = try XCTUnwrap(monitor.recordFailure(
            RemoteCompletionError.badStatus(503, ""),
            at: now.addingTimeInterval(2)
        ))
        let suppressUntil = try XCTUnwrap(paused.suppressUntil)

        let summary = try XCTUnwrap(monitor.recordFailure(
            RemoteCompletionError.badStatus(401, ""),
            at: now.addingTimeInterval(3)
        ))

        XCTAssertEqual(summary.state, .paused)
        XCTAssertEqual(summary.issue, .unauthorized)
        XCTAssertEqual(summary.suppressUntil, suppressUntil)
        XCTAssertEqual(monitor.circuitBreaker.consecutiveFailures, 0)
        XCTAssertEqual(monitor.circuitBreaker.suppressUntil, suppressUntil)
        XCTAssertFalse(monitor.allowsAutomaticTrigger(at: now.addingTimeInterval(4)))
        XCTAssertEqual(monitor.refresh(at: now.addingTimeInterval(33)).state, .disconnected)
    }

    func testNonRemoteFailuresAreNotTracked() {
        var monitor = BackendHealthMonitor()

        XCTAssertNil(monitor.recordFailure(TestError.failed))
        XCTAssertEqual(monitor.summary.state, .connected)
    }
}

private enum TestError: Error {
    case failed
}
