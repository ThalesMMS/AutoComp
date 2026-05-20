@testable import AutoCompCore
import XCTest

final class DurationMillisecondsTests: XCTestCase {
    func testMillisecondsConvertsSharedDurationValue() {
        let duration = Duration.seconds(1) + .milliseconds(234)

        XCTAssertEqual(duration.milliseconds, 1_234)
    }
}
