import XCTest
@testable import AutoCompCore

final class StaleWorkStepTests: XCTestCase {
    func testContinuesWhenNotCancelledAndCurrent() async {
        let requestId = UUID()
        var context = SuggestionPipeline.RequestContext(requestId: requestId)
        let step = SuggestionPipeline.StaleWorkStep<String>(isCurrent: { $0 == requestId })

        let outcome = await step.handle(context: &context)

        XCTAssertEqual(outcome, .continue)
    }

    func testDiscardsWhenNotCurrent() async {
        let requestId = UUID()
        var context = SuggestionPipeline.RequestContext(requestId: requestId)
        let step = SuggestionPipeline.StaleWorkStep<String>(isCurrent: { _ in false })

        let outcome = await step.handle(context: &context)

        XCTAssertEqual(outcome, .discard(.stale))
    }

    func testDiscardsWhenCancelled() async {
        let requestId = UUID()
        let step = SuggestionPipeline.StaleWorkStep<String>(isCurrent: { $0 == requestId })

        let outcome: SuggestionPipeline.Outcome<String> = await Task {
            var context = SuggestionPipeline.RequestContext(requestId: requestId)
            return await step.handle(context: &context)
        }.value

        // This task is not cancelled, so it should continue.
        XCTAssertEqual(outcome, .continue)

        // We can't reliably cancel the task after creation without additional synchronization.
        // Validate the cancellation path by explicitly cancelling before awaiting.
        let cancellationTask = Task<SuggestionPipeline.Outcome<String>, Never> {
            var context = SuggestionPipeline.RequestContext(requestId: requestId)
            return await step.handle(context: &context)
        }
        cancellationTask.cancel()
        let cancellationOutcome = await cancellationTask.value
        XCTAssertEqual(cancellationOutcome, .discard(.cancelled))
    }
}
