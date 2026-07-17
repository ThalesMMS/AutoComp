import AutoCompCore
import XCTest

final class SuggestionSchedulingPolicyTests: XCTestCase {
    func testHostPublishTimeIsSubtractedFromTarget() {
        let policy = SuggestionSchedulingPolicy(configuration: .init(
            localTargetMs: 40, appleTargetMs: 40, remoteTargetMs: 40,
            minimumTargetMs: 0, maximumTargetMs: 500
        ))
        let decision = policy.decision(.init(
            route: .localLlama, invocation: .automatic, mutation: .insert,
            hostPublishElapsedMs: 10, hostPublishOutcome: .published
        ))
        XCTAssertEqual(decision.targetDebounceMs, 40)
        XCTAssertEqual(decision.remainingDebounceMs, 30)
        XCTAssertEqual(decision.action, .debounce)
    }

    func testHostPublishLongerThanTargetGeneratesImmediately() {
        let policy = SuggestionSchedulingPolicy(configuration: .init(
            localTargetMs: 40, minimumTargetMs: 0
        ))
        let decision = policy.decision(.init(
            route: .localLlama, invocation: .automatic, mutation: .insert,
            hostPublishElapsedMs: 80, hostPublishOutcome: .published
        ))
        XCTAssertEqual(decision.remainingDebounceMs, 0)
        XCTAssertTrue(decision.shouldGenerateImmediately)
        XCTAssertEqual(decision.reason, .hostPublishConsumedWindow)
    }

    func testRoutesHaveDeterministicFirstUseTargets() {
        let policy = SuggestionSchedulingPolicy()
        let decisions = CompletionEngineKind.allCases.map {
            policy.decision(.init(route: $0, invocation: .automatic, mutation: .insert))
        }
        XCTAssertEqual(decisions.map(\.targetDebounceMs), [260, 80, 140])
        XCTAssertEqual(Set(decisions.map(\.reason)), [.adaptiveRoute])
    }

    func testLatencyAndRapidTypingAdaptWithinBounds() {
        let policy = SuggestionSchedulingPolicy()
        let remoteSlow = policy.decision(.init(
            route: .remote, invocation: .automatic, mutation: .insert,
            recentBackendLatencyMs: 2_000, recentTypingIntervalMs: 50
        ))
        let localFast = policy.decision(.init(
            route: .localLlama, invocation: .automatic, mutation: .insert,
            recentBackendLatencyMs: 20, recentTypingIntervalMs: 500
        ))
        XCTAssertEqual(remoteSlow.targetDebounceMs, 480)
        XCTAssertEqual(localFast.targetDebounceMs, 60)
    }

    func testManualCompositionAndKillSwitchAreExplicit() {
        let policy = SuggestionSchedulingPolicy()
        XCTAssertEqual(policy.decision(.init(
            route: .remote, invocation: .manual, mutation: .insert
        )).action, .generateImmediately)
        XCTAssertEqual(policy.decision(.init(
            route: .remote, invocation: .automatic, mutation: .insert, isComposingText: true
        )).action, .suppress)

        let fixed = SuggestionSchedulingPolicy(configuration: .init(adaptiveEnabled: false))
            .decision(.init(
                route: .localLlama, invocation: .automatic, mutation: .insert,
                hostPublishElapsedMs: 200
            ))
        XCTAssertEqual(fixed.remainingDebounceMs, 250)
        XCTAssertEqual(fixed.reason, .fixedKillSwitch)
        XCTAssertFalse(SuggestionSchedulingPolicy.Configuration.environmentDefault(
            environment: ["AUTOCOMP_DISABLE_ADAPTIVE_SCHEDULING": "true"]
        ).adaptiveEnabled)
        XCTAssertTrue(SuggestionSchedulingPolicy.Configuration.environmentDefault(
            environment: [:]
        ).adaptiveEnabled)
    }

    func testLatencyHistoryUsesShortMedianAndIsolatesOutlier() {
        var history = SuggestionBackendLatencyHistory(maximumSamplesPerRoute: 5)
        for sample in [100, 110, 90, 105, 9_000] { history.record(sample, for: .remote) }
        history.record(20, for: .localLlama)

        XCTAssertEqual(history.robustLatencyMs(for: .remote), 105)
        XCTAssertEqual(history.robustLatencyMs(for: .localLlama), 20)
        XCTAssertEqual(history.sampleCount(for: .remote), 5)
    }
}
