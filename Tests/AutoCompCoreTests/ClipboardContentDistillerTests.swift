import AutoCompCore
import XCTest

final class ClipboardContentDistillerTests: XCTestCase {
    func testSmallRelevantClipboardPassesIntact() {
        let text = """
        Launch plan
        Update onboarding
        """

        let distilled = ClipboardContentDistiller().distill(text, matchingTokens: ["launch"])

        XCTAssertEqual(distilled, "Launch plan\nUpdate onboarding")
    }

    func testLongClipboardKeepsRelevantLinesWithinLimits() {
        let text = """
        Invoice total due Friday
        Launch plan needs onboarding update
        Random unrelated status
        Release launch checklist owner
        Another unrelated paragraph
        """

        let distilled = ClipboardContentDistiller(maxLines: 2, maxCharacters: 80)
            .distill(text, matchingTokens: ["launch"])

        XCTAssertEqual(
            distilled,
            "Launch plan needs onboarding update\nRelease launch checklist owner"
        )
        XCTAssertLessThanOrEqual(distilled.count, 80)
    }
}
