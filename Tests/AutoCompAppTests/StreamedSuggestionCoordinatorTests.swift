import AutoCompCore
import XCTest
@testable import AutoCompApp

@MainActor
final class StreamedSuggestionCoordinatorTests: XCTestCase {
    func testTwoPartialsInOneRunLoopRenderOnlyLatest() async {
        let coordinator = StreamedSuggestionCoordinator()
        let metadata = makeMetadata()
        let context = makeContext()
        var rendered: [String] = []
        coordinator.begin(metadata)

        coordinator.receive(makePartial("hel", sequence: 1, metadata: metadata), context: context) { _, text, _ in
            rendered.append(text)
        }
        coordinator.receive(makePartial("hello", sequence: 2, metadata: metadata), context: context) { _, text, _ in
            rendered.append(text)
        }

        await Task.yield()
        await Task.yield()
        XCTAssertEqual(rendered, ["hello"])
        XCTAssertEqual(coordinator.metrics.partialsCoalesced, 1)
        XCTAssertEqual(coordinator.metrics.partialsRendered, 1)
    }

    func testOldWorkAndFrozenAcceptanceDoNotRender() async {
        let coordinator = StreamedSuggestionCoordinator()
        let active = makeMetadata(workID: 2)
        let stale = makeMetadata(workID: 1)
        let context = makeContext()
        var rendered = 0
        coordinator.begin(active)

        coordinator.receive(makePartial("old", sequence: 1, metadata: stale), context: context) { _, _, _ in rendered += 1 }
        let suggestion = Suggestion(
            baseContextID: context.id,
            visibleText: "hel",
            traceContext: active.traceContext,
            streamingMetadata: .init(traceID: active.traceContext.traceID, workID: active.workID, providerSequence: 1, isFinal: false),
            latencyMs: 1
        )
        XCTAssertTrue(coordinator.freezeForEarlyAcceptance(suggestion))
        coordinator.receive(makePartial("hello", sequence: 2, metadata: active), context: context) { _, _, _ in rendered += 1 }
        await Task.yield()
        XCTAssertEqual(rendered, 0)
        coordinator.retireAfterEarlyAcceptance()
        XCTAssertEqual(coordinator.metrics.worksCancelledByAcceptance, 1)
    }

    func testFinalBeforeDrainTerminalizesPendingSafePartial() async {
        let coordinator = StreamedSuggestionCoordinator()
        let metadata = makeMetadata()
        let context = makeContext()
        var rendered: [CompletionPartial] = []
        coordinator.begin(metadata)

        coordinator.receive(makePartial("hello", sequence: 1, metadata: metadata), context: context) { partial, _, _ in
            rendered.append(partial)
        }
        coordinator.receive(
            makePartial("hello", sequence: 2, metadata: metadata, isFinal: true),
            context: context
        ) { partial, _, _ in
            rendered.append(partial)
        }

        await Task.yield()
        await Task.yield()
        XCTAssertEqual(rendered.count, 1)
        XCTAssertTrue(rendered[0].isFinal)
        XCTAssertEqual(rendered[0].providerSequence, 2)
    }

    func testFeatureFlagIsOffByDefaultAndLocalOnlyWhenEnabled() {
        XCTAssertEqual(StreamingCompletionFeature.configuration(environment: [:]), .disabled)
        let enabled = StreamingCompletionFeature.configuration(environment: [
            StreamingCompletionFeature.localLlamaEnvironmentKey: "true"
        ])
        XCTAssertTrue(enabled.enables(.init(route: .localLlama)))
        XCTAssertFalse(enabled.enables(.init(route: .remote)))
    }

    private func makeMetadata(workID: Int = 1) -> StreamingCompletionMetadata {
        .init(traceContext: CompletionTraceContext(), workID: workID, requestedRoute: .localLlama)
    }

    private func makePartial(
        _ text: String,
        sequence: Int,
        metadata: StreamingCompletionMetadata,
        isFinal: Bool = false
    ) -> CompletionPartial {
        .init(
            metadata: metadata,
            accumulatedText: text,
            providerSequence: sequence,
            route: .init(requestedKind: .localLlama, deliveredKind: .localLlama),
            phase: isFinal ? .final : .partial,
            latencyMs: sequence
        )
    }

    private func makeContext() -> TextContext {
        .init(
            app: .init(bundleID: "com.test", displayName: "Test", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: "Say ",
            textAfterCursor: ""
        )
    }
}
