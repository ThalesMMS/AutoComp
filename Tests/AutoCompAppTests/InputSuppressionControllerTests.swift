import AppKit
@testable import AutoCompApp
import XCTest

final class InputSuppressionControllerTests: XCTestCase {
    func testShortcutConsumptionExtendsGraceSuppressesOneReleaseAndDeduplicatesTimestamp() {
        let clock = InputSuppressionTestClock()
        let controller = InputSuppressionController(
            shortcutGraceInterval: 0.5,
            keyReleaseSuppressionInterval: 0.75,
            now: { clock.now }
        )

        XCTAssertFalse(controller.isShortcutArmed)
        XCTAssertTrue(controller.consumeShortcutIfNeeded(keyCode: 48, eventTimestamp: 123))
        XCTAssertTrue(controller.isShortcutArmed)
        XCTAssertTrue(controller.consumeSuppressedKeyRelease(keyCode: 48))
        XCTAssertFalse(controller.consumeSuppressedKeyRelease(keyCode: 48))
        XCTAssertFalse(controller.consumeShortcutIfNeeded(keyCode: 48, eventTimestamp: 123))

        clock.advance(by: 0.6)
        XCTAssertFalse(controller.isShortcutArmed)
        XCTAssertFalse(controller.consumeSuppressedKeyRelease(keyCode: 48))
    }

    func testSyntheticInsertionConsumesExpectedKeyDownAndKeyUpCounts() throws {
        let clock = InputSuppressionTestClock()
        let controller = InputSuppressionController(
            syntheticInputSuppressionInterval: 0.5,
            now: { clock.now }
        )
        let keyDown = try makeKeyboardEvent(keyCode: 0, keyDown: true)
        let keyUp = try makeKeyboardEvent(keyCode: 0, keyDown: false)

        XCTAssertFalse(controller.consumeIfSynthetic(event: keyDown))
        controller.registerSyntheticInsertion(expectedKeyDownCount: 1, expectedKeyUpCount: 1)
        XCTAssertTrue(controller.consumeIfSynthetic(event: keyDown))
        XCTAssertFalse(controller.consumeIfSynthetic(event: keyDown))
        XCTAssertTrue(controller.consumeIfSynthetic(event: keyUp))
        XCTAssertFalse(controller.consumeIfSynthetic(event: keyUp))
    }

    func testSyntheticInsertionConsumesPerCharacterCountsExactly() throws {
        let clock = InputSuppressionTestClock()
        let controller = InputSuppressionController(
            syntheticInputSuppressionInterval: 0.5,
            now: { clock.now }
        )
        let keyDown = try makeKeyboardEvent(keyCode: 0, keyDown: true)
        let keyUp = try makeKeyboardEvent(keyCode: 0, keyDown: false)

        controller.registerSyntheticInsertion(expectedKeyDownCount: 3, expectedKeyUpCount: 3)

        XCTAssertTrue(controller.consumeIfSynthetic(event: keyDown))
        XCTAssertTrue(controller.consumeIfSynthetic(event: keyDown))
        XCTAssertTrue(controller.consumeIfSynthetic(event: keyDown))
        XCTAssertFalse(controller.consumeIfSynthetic(event: keyDown))
        XCTAssertTrue(controller.consumeIfSynthetic(event: keyUp))
        XCTAssertTrue(controller.consumeIfSynthetic(event: keyUp))
        XCTAssertTrue(controller.consumeIfSynthetic(event: keyUp))
        XCTAssertFalse(controller.consumeIfSynthetic(event: keyUp))
    }

    func testSyntheticInsertionIgnoresNonKeyboardEventsAndExpiresBudget() throws {
        let clock = InputSuppressionTestClock()
        let controller = InputSuppressionController(
            syntheticInputSuppressionInterval: 0.5,
            now: { clock.now }
        )
        let keyDown = try makeKeyboardEvent(keyCode: 0, keyDown: true)
        let keyUp = try makeKeyboardEvent(keyCode: 0, keyDown: false)
        let flagsChanged = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 60, keyDown: true))
        flagsChanged.type = .flagsChanged

        controller.registerSyntheticInsertion(expectedKeyDownCount: 1, expectedKeyUpCount: 1)
        XCTAssertFalse(controller.consumeIfSynthetic(event: flagsChanged))
        XCTAssertTrue(controller.consumeIfSynthetic(event: keyDown))
        XCTAssertTrue(controller.consumeIfSynthetic(event: keyUp))

        controller.registerSyntheticInsertion(expectedKeyDownCount: 1, expectedKeyUpCount: 1)

        clock.advance(by: 0.6)
        XCTAssertFalse(controller.consumeIfSynthetic(event: keyDown))
        XCTAssertFalse(controller.consumeIfSynthetic(event: keyUp))
    }

    func testClearingConsumedShortcutAllowsPassthroughReplayRelease() {
        let clock = InputSuppressionTestClock()
        let controller = InputSuppressionController(
            shortcutGraceInterval: 0.5,
            keyReleaseSuppressionInterval: 0.75,
            now: { clock.now }
        )

        XCTAssertTrue(controller.consumeShortcutIfNeeded(keyCode: 48, eventTimestamp: 123))
        XCTAssertTrue(controller.isShortcutArmed)

        controller.clearConsumedShortcut(keyCode: 48)

        XCTAssertFalse(controller.isShortcutArmed)
        XCTAssertFalse(controller.consumeSuppressedKeyRelease(keyCode: 48))
        XCTAssertTrue(controller.consumeShortcutIfNeeded(keyCode: 48, eventTimestamp: 123))
    }
}

private func makeKeyboardEvent(keyCode: CGKeyCode, keyDown: Bool) throws -> CGEvent {
    try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown))
}

private final class InputSuppressionTestClock {
    private(set) var now = Date(timeIntervalSince1970: 1_000)

    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }
}
