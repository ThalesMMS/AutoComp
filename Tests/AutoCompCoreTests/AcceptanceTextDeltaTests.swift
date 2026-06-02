import AutoCompCore
import XCTest

final class AcceptanceTextDeltaTests: XCTestCase {
    func testTrimsExactSuffixOverlap() {
        XCTAssertEqual(
            AcceptanceTextDelta.trimmingSuffixOverlap(token: "Hello world", suffix: " world"),
            "Hello"
        )
    }

    func testKeepsTokenWhenSuffixDoesNotOverlap() {
        XCTAssertEqual(
            AcceptanceTextDelta.trimmingSuffixOverlap(token: "Hello there", suffix: " world"),
            "Hello there"
        )
    }

    func testKeepsEmptyToken() {
        XCTAssertEqual(
            AcceptanceTextDelta.trimmingSuffixOverlap(token: "", suffix: " world"),
            ""
        )
    }
}
