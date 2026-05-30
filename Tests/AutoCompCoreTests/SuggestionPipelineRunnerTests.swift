import XCTest
@testable import AutoCompCore

final class SuggestionPipelineRunnerTests: XCTestCase {
    private struct ContinueStep: SuggestionPipeline.Step {
        typealias Payload = String

        let key: String
        let value: String

        func handle(context: inout SuggestionPipeline.RequestContext) async -> SuggestionPipeline.Outcome<String> {
            context.userInfo[key] = value
            return .continue
        }
    }

    private struct DiscardStep: SuggestionPipeline.Step {
        typealias Payload = String

        let reason: SuggestionPipeline.DiscardReason

        func handle(context: inout SuggestionPipeline.RequestContext) async -> SuggestionPipeline.Outcome<String> {
            _ = context
            return .discard(reason)
        }
    }

    func testRunnerStopsAtFirstTerminalOutcome() async {
        var context = SuggestionPipeline.RequestContext(userInfo: [:])

        let runner = SuggestionPipeline.Runner<String>(steps: [
            ContinueStep(key: "a", value: "1"),
            DiscardStep(reason: .stale),
            ContinueStep(key: "b", value: "2")
        ])

        let outcome = await runner.run(context: &context)

        XCTAssertEqual(outcome, .discard(.stale))
        XCTAssertEqual(context.userInfo["a"] as? String, "1")
        XCTAssertNil(context.userInfo["b"])
    }

    func testRunnerReturnsContinueWhenAllStepsContinue() async {
        var context = SuggestionPipeline.RequestContext(userInfo: [:])

        let runner = SuggestionPipeline.Runner<String>(steps: [
            ContinueStep(key: "a", value: "1"),
            ContinueStep(key: "b", value: "2")
        ])

        let outcome = await runner.run(context: &context)

        XCTAssertEqual(outcome, .continue)
        XCTAssertEqual(context.userInfo["a"] as? String, "1")
        XCTAssertEqual(context.userInfo["b"] as? String, "2")
    }
}
