import AutoCompCore
import XCTest

final class VisualContextEligibilityStepTests: XCTestCase {
    func testStoresIneligibleWhenDisabled() async {
        let step = VisualContextEligibilityStep<String>(
            inputs: .init(
                visualContextEnabled: { false },
                visualContextProviderAvailable: { true }
            )
        )

        var context = SuggestionPipeline.RequestContext()
        let outcome = await step.handle(context: &context)

        XCTAssertEqual(outcome, .continue)
        let decision = context.userInfo[VisualContextEligibilityStep<String>.decisionUserInfoKey] as? VisualContextEligibilityStep<String>.Decision
        XCTAssertEqual(decision, .ineligible(reason: "disabled"))
    }

    func testStoresIneligibleWhenProviderUnavailable() async {
        let step = VisualContextEligibilityStep<String>(
            inputs: .init(
                visualContextEnabled: { true },
                visualContextProviderAvailable: { false }
            )
        )

        var context = SuggestionPipeline.RequestContext()
        let outcome = await step.handle(context: &context)

        XCTAssertEqual(outcome, .continue)
        let decision = context.userInfo[VisualContextEligibilityStep<String>.decisionUserInfoKey] as? VisualContextEligibilityStep<String>.Decision
        XCTAssertEqual(decision, .ineligible(reason: "unavailable"))
    }

    func testStoresEligibleWhenEnabledAndAvailable() async {
        let step = VisualContextEligibilityStep<String>(
            inputs: .init(
                visualContextEnabled: { true },
                visualContextProviderAvailable: { true }
            )
        )

        var context = SuggestionPipeline.RequestContext()
        let outcome = await step.handle(context: &context)

        XCTAssertEqual(outcome, .continue)
        let decision = context.userInfo[VisualContextEligibilityStep<String>.decisionUserInfoKey] as? VisualContextEligibilityStep<String>.Decision
        XCTAssertEqual(decision, .eligible)
    }
}
