import Foundation
@testable import AutoCompCore
import XCTest

final class StreamedSuggestionPolicyTests: XCTestCase {
    func testMonotonicSequenceRendersOnlyExactExtensions() {
        var policy = StreamedSuggestionPolicy()
        let context = makeContext(textBeforeCursor: "Say ")

        XCTAssertEqual(policy.evaluate(partial("hel", sequence: 1), context: context), .render("hel"))
        XCTAssertEqual(policy.evaluate(partial("hello", sequence: 2), context: context), .render("hello"))
        XCTAssertEqual(policy.evaluate(partial("hello world", sequence: 3), context: context), .render("hello world"))
        XCTAssertEqual(policy.renderedText, "hello world")
    }

    func testShorterDivergentAndOutOfOrderPartialsAreIgnored() {
        var policy = StreamedSuggestionPolicy()
        let context = makeContext(textBeforeCursor: "Say ")
        _ = policy.evaluate(partial("hello", sequence: 2), context: context)

        XCTAssertEqual(policy.evaluate(partial("hell", sequence: 3), context: context), .ignore(.nonMonotonic))
        XCTAssertEqual(policy.evaluate(partial("hullo", sequence: 4), context: context), .ignore(.nonMonotonic))
        XCTAssertEqual(policy.evaluate(partial("hello world", sequence: 1), context: context), .ignore(.outOfOrder))
        XCTAssertEqual(policy.renderedText, "hello")
    }

    func testFinalIncompatibleKeepsValidatedPartialAndMarkerWithoutPartialHides() {
        var policy = StreamedSuggestionPolicy()
        let context = makeContext(textBeforeCursor: "Say ")
        _ = policy.evaluate(partial("hello", sequence: 1), context: context)

        XCTAssertEqual(
            policy.evaluate(partial("help", sequence: 2, phase: .final), context: context),
            .keepCurrent(.nonMonotonic)
        )

        var emptyPolicy = StreamedSuggestionPolicy()
        XCTAssertEqual(
            emptyPolicy.evaluate(partial("<|end|>", sequence: 1, phase: .final), context: context),
            .hide(.controlMarker)
        )
    }

    func testFinalEqualToRenderedTextFinalizesWithoutAnotherRender() {
        var policy = StreamedSuggestionPolicy()
        let context = makeContext(textBeforeCursor: "Say ")
        _ = policy.evaluate(partial("hello", sequence: 1), context: context)

        XCTAssertEqual(
            policy.evaluate(partial("hello", sequence: 2, phase: .final), context: context),
            .finalizeCurrent
        )
    }

    private func partial(
        _ text: String,
        sequence: Int,
        phase: CompletionPartialPhase = .partial
    ) -> CompletionPartial {
        CompletionPartial(
            metadata: StreamingCompletionMetadata(
                traceContext: CompletionTraceContext(),
                workID: 1,
                requestedRoute: .localLlama
            ),
            accumulatedText: text,
            providerSequence: sequence,
            route: CompletionRoute(requestedKind: .localLlama, deliveredKind: .localLlama),
            phase: phase,
            latencyMs: sequence
        )
    }
}
