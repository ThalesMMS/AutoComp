@testable import AutoCompApp
import XCTest

final class InputSuppressionControllerTests: XCTestCase {
    func testShortcutConsumptionExtendsGraceSuppressesReleaseAndDeduplicatesTimestamp() {
        let clock = InputSuppressionTestClock()
        let controller = InputSuppressionController(
            shortcutGraceInterval: 0.5,
            keyReleaseSuppressionInterval: 0.75,
            now: { clock.now }
        )

        XCTAssertFalse(controller.isShortcutArmed)
        XCTAssertTrue(controller.consumeShortcutIfNeeded(keyCode: 48, eventTimestamp: 123))
        XCTAssertTrue(controller.isShortcutArmed)
        XCTAssertTrue(controller.shouldSuppressKeyRelease(keyCode: 48))
        XCTAssertFalse(controller.consumeShortcutIfNeeded(keyCode: 48, eventTimestamp: 123))

        clock.advance(by: 0.6)
        XCTAssertFalse(controller.isShortcutArmed)
        XCTAssertTrue(controller.shouldSuppressKeyRelease(keyCode: 48))

        clock.advance(by: 0.2)
        XCTAssertFalse(controller.shouldSuppressKeyRelease(keyCode: 48))
    }

    func testSyntheticTextInputIsSuppressedOnlyInsideWindow() {
        let clock = InputSuppressionTestClock()
        let controller = InputSuppressionController(
            syntheticInputSuppressionInterval: 0.5,
            now: { clock.now }
        )
        let inputEvent = CapturedInputEvent.text(keyCode: 49, isSuggestionTrigger: true)

        XCTAssertFalse(controller.shouldSuppressSyntheticInput(inputEvent))
        controller.recordSyntheticInput()
        XCTAssertTrue(controller.shouldSuppressSyntheticInput(inputEvent))
        XCTAssertFalse(controller.shouldSuppressSyntheticInput(.tab))

        clock.advance(by: 0.6)
        XCTAssertFalse(controller.shouldSuppressSyntheticInput(inputEvent))
    }
}

private final class InputSuppressionTestClock {
    private(set) var now = Date(timeIntervalSince1970: 1_000)

    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }
}
