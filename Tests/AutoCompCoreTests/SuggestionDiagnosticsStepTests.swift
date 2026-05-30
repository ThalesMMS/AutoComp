import AutoCompCore
import Foundation
import Testing

struct SuggestionDiagnosticsStepTests {

    @Test
    func startedStageAppendsPipelineStartedEvent() async {
        var context = SuggestionPipeline.RequestContext()
        let step = SuggestionDiagnosticsStep<String>(stage: .started, now: { Date(timeIntervalSince1970: 123) })

        let outcome = await step.handle(context: &context)

        #expect(outcome == .continue)
        #expect(context.diagnostics.events.count == 1)
        #expect(context.diagnostics.events[0].kind == .note)
        #expect(context.diagnostics.events[0].name == SuggestionDiagnosticsEventName.pipelineStarted)
    }

    @Test
    func finishedStageAppendsPipelineFinishedEvent() async {
        var context = SuggestionPipeline.RequestContext()
        let step = SuggestionDiagnosticsStep<String>(stage: .finished, now: { Date(timeIntervalSince1970: 123) })

        _ = await step.handle(context: &context)

        #expect(context.diagnostics.events.count == 1)
        #expect(context.diagnostics.events[0].name == SuggestionDiagnosticsEventName.pipelineFinished)
    }

    @Test
    func recordDiscardAppendsDiscardEvent() {
        var context = SuggestionPipeline.RequestContext()
        context.recordDiscard(.init(kind: .privacy, message: "private-mode"))

        #expect(context.diagnostics.events.count == 1)
        #expect(context.diagnostics.events[0].kind == .discard)
        #expect(context.diagnostics.events[0].name == SuggestionDiagnosticsEventName.discardReason)
        #expect(context.diagnostics.events[0].value?.contains("privacy") == true)
    }
}
