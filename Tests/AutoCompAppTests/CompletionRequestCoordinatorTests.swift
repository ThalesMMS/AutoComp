import AutoCompCore
@testable import AutoCompApp
import XCTest

final class CompletionRequestCoordinatorTests: XCTestCase {
    func testPreflightHandlesSuspensionAndAutomaticBackendSuppression() {
        let coordinator = CompletionRequestCoordinator()
        var monitor = BackendHealthMonitor(circuitBreaker: RemoteCircuitBreaker(
            failureThreshold: 1,
            suppressionInterval: 60
        ))

        XCTAssertEqual(
            coordinator.preflight(
                isPipelineSuspended: true,
                isAutomatic: true,
                backendHealthMonitor: &monitor
            ),
            .pipelineSuspended
        )

        let paused = monitor.recordFailure(issue: .offline)
        XCTAssertEqual(
            coordinator.preflight(
                isPipelineSuspended: false,
                isAutomatic: true,
                backendHealthMonitor: &monitor
            ),
            .backendSuppressed(paused)
        )
        XCTAssertEqual(
            coordinator.preflight(
                isPipelineSuspended: false,
                isAutomatic: false,
                backendHealthMonitor: &monitor
            ),
            .proceed(paused)
        )
    }

    func testInvocationOwnsStaleGateProviderCallAndLatency() async {
        let coordinator = CompletionRequestCoordinator()
        let textContext = TextContext(
            app: AppIdentity(bundleID: "com.example.Editor", displayName: "Editor", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: "hello "
        )
        let provider = CoordinatorCompletionProvider(contextID: textContext.id)
        let metadata = StreamingCompletionMetadata(
            traceContext: CompletionTraceContext(),
            workID: 1,
            requestedRoute: .remote
        )
        var requestContext = SuggestionPipeline.RequestContext(textContext: textContext)
        requestContext.prepareProviderInvocation(privacySettings: PrivacySettings())

        let result = await coordinator.invoke(
            context: &requestContext,
            provider: provider,
            isCurrent: true,
            streamingConfiguration: .disabled,
            streamingMetadata: metadata,
            onPartial: { _ in }
        )

        guard case .publish(let suggestion) = result.outcome else {
            return XCTFail("Expected provider publication")
        }
        XCTAssertEqual(suggestion.visibleText, "world")
        XCTAssertGreaterThanOrEqual(result.backendLatencyMs, 0)
        let publishedCallCount = await provider.recordedCallCount()
        XCTAssertEqual(publishedCallCount, 1)

        var staleContext = SuggestionPipeline.RequestContext(textContext: textContext)
        staleContext.prepareProviderInvocation(privacySettings: PrivacySettings())
        let staleResult = await coordinator.invoke(
            context: &staleContext,
            provider: provider,
            isCurrent: false,
            streamingConfiguration: .disabled,
            streamingMetadata: metadata,
            onPartial: { _ in }
        )

        guard case .discard(let reason) = staleResult.outcome else {
            return XCTFail("Expected stale discard")
        }
        XCTAssertEqual(reason.kind, .stale)
        let finalCallCount = await provider.recordedCallCount()
        XCTAssertEqual(finalCallCount, 1)
    }
}

private actor CoordinatorCompletionProvider: CompletionProvider {
    private let contextID: UUID
    private(set) var callCount = 0

    init(contextID: UUID) {
        self.contextID = contextID
    }

    func complete(context: TextContext) async throws -> Suggestion {
        callCount += 1
        return Suggestion(baseContextID: contextID, visibleText: "world", latencyMs: 0)
    }

    func recordedCallCount() -> Int {
        callCount
    }
}
