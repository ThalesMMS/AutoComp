import AutoCompCore
import XCTest

final class SuggestionPublicationPolicyTests: XCTestCase {
    func testProductionPublicationPolicyTrimsAfterTriggerWhitespace() {
        let context = TextContext(
            app: AppIdentity(bundleID: "test", displayName: "Test", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: "Hello "
        )
        let suggestion = Suggestion(baseContextID: context.id, visibleText: " \nworld", latencyMs: 1)

        guard case .publish(let normalized) = SuggestionPublicationPolicy.evaluate(suggestion, for: context) else {
            return XCTFail("Expected publication")
        }
        XCTAssertEqual(normalized.visibleText, "world")
        XCTAssertEqual(normalized.remainingText, "world")
    }

    func testProductionPublicationPolicySuppressesWhitespaceOnlyResult() {
        let context = TextContext(
            app: AppIdentity(bundleID: "test", displayName: "Test", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: "Hello "
        )
        let suggestion = Suggestion(baseContextID: context.id, visibleText: " \n", latencyMs: 1)

        XCTAssertEqual(SuggestionPublicationPolicy.evaluate(suggestion, for: context), .suppressEmpty)
    }
}
