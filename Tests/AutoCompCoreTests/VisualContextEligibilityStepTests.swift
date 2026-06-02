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

    func testStoresIneligibleWhenScreenRecordingIsOff() async {
        let step = VisualContextEligibilityStep<String>(
            inputs: .init(
                visualContextEnabled: { true },
                visualContextProviderAvailable: { true },
                screenRecordingAllowed: { false }
            )
        )

        var context = SuggestionPipeline.RequestContext()
        _ = await step.handle(context: &context)

        let decision = context.userInfo[VisualContextEligibilityStep<String>.decisionUserInfoKey] as? VisualContextEligibilityStep<String>.Decision
        XCTAssertEqual(decision, .ineligible(reason: "screen-recording-off"))
    }

    func testStoresIneligibleWhenAppDomainIsDisabled() async {
        let step = VisualContextEligibilityStep<String>(
            inputs: .init(
                visualContextEnabled: { true },
                visualContextProviderAvailable: { true },
                appDomainAllowed: { false }
            )
        )

        var context = SuggestionPipeline.RequestContext()
        _ = await step.handle(context: &context)

        let decision = context.userInfo[VisualContextEligibilityStep<String>.decisionUserInfoKey] as? VisualContextEligibilityStep<String>.Decision
        XCTAssertEqual(decision, .ineligible(reason: "app-domain-disabled"))
    }

    func testStoresIneligibleForSecureField() async {
        let step = VisualContextEligibilityStep<String>(
            inputs: .init(
                visualContextEnabled: { true },
                visualContextProviderAvailable: { true },
                fieldSecure: { true }
            )
        )

        var context = SuggestionPipeline.RequestContext()
        _ = await step.handle(context: &context)

        let decision = context.userInfo[VisualContextEligibilityStep<String>.decisionUserInfoKey] as? VisualContextEligibilityStep<String>.Decision
        XCTAssertEqual(decision, .ineligible(reason: "secure-field"))
    }

    func testStoresIneligibleWhenAutocompleteIsIneligible() async {
        let step = VisualContextEligibilityStep<String>(
            inputs: .init(
                visualContextEnabled: { true },
                visualContextProviderAvailable: { true },
                autocompleteEligible: { false }
            )
        )

        var context = SuggestionPipeline.RequestContext()
        _ = await step.handle(context: &context)

        let decision = context.userInfo[VisualContextEligibilityStep<String>.decisionUserInfoKey] as? VisualContextEligibilityStep<String>.Decision
        XCTAssertEqual(decision, .ineligible(reason: "autocomplete-ineligible"))
    }
}
