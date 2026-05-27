import AutoCompCore
import XCTest

final class ClipboardRelevanceFilterTests: XCTestCase {
    func testRelatedClipboardOverlapsPrefixTokens() {
        let decision = ClipboardRelevanceFilter().evaluate(
            clipboardText: "Launch plan: update onboarding and release notes.",
            textBeforeCursor: "Please summarize the launch plan"
        )

        XCTAssertTrue(decision.isRelevant)
        XCTAssertTrue(decision.overlappingTokens.contains("launch"))
        XCTAssertTrue(decision.overlappingTokens.contains("plan"))
    }

    func testUnrelatedClipboardIsNotRelevant() {
        let decision = ClipboardRelevanceFilter().evaluate(
            clipboardText: "Invoice total and payment method.",
            textBeforeCursor: "Please summarize the launch plan"
        )

        XCTAssertFalse(decision.isRelevant)
        XCTAssertTrue(decision.overlappingTokens.isEmpty)
    }
}
