import AppKit
@testable import AutoCompApp
import XCTest

final class KeyboardShortcutServiceTests: XCTestCase {
    func testBacktickPassesThroughWhenSuggestionIsActive() throws {
        let service = KeyboardShortcutService()
        service.configureHandlers(onTab: {}, onAcceptAll: {})
        service.setSuggestionActive(true)

        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 50, keyDown: true))
        event.flags = []
        let result = service.handle(type: .keyDown, event: event)

        XCTAssertNotNil(result)
    }

    func testBacktickPassesThroughWhenSuggestionIsInactive() throws {
        let service = KeyboardShortcutService()
        service.configureHandlers(onTab: {}, onAcceptAll: {})
        service.setSuggestionActive(false)

        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 50, keyDown: true))
        event.flags = []
        let result = service.handle(type: .keyDown, event: event)

        XCTAssertNotNil(result)
    }

    @MainActor
    func testRightShiftAcceptsAllWhenSuggestionIsActive() async throws {
        let service = KeyboardShortcutService()
        let accepted = expectation(description: "accept all")
        service.configureHandlers(
            onTab: {},
            onAcceptAll: {
                accepted.fulfill()
            }
        )
        service.setSuggestionActive(true)

        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 60, keyDown: true))
        event.flags = .maskShift
        let result = service.handle(type: .flagsChanged, event: event)

        XCTAssertNil(result)
        await fulfillment(of: [accepted], timeout: 1)
    }

    @MainActor
    func testRightShiftReleaseIsSuppressedAfterConsumedPress() async throws {
        let service = KeyboardShortcutService()
        let accepted = expectation(description: "accept all")
        service.configureHandlers(
            onTab: {},
            onAcceptAll: {
                accepted.fulfill()
            }
        )
        service.setSuggestionActive(true)

        let keyDown = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 60, keyDown: true))
        keyDown.flags = .maskShift
        XCTAssertNil(service.handle(type: .flagsChanged, event: keyDown))

        let keyUp = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 60, keyDown: false))
        keyUp.flags = []
        XCTAssertNil(service.handle(type: .flagsChanged, event: keyUp))
        await fulfillment(of: [accepted], timeout: 1)
    }

    func testRightShiftPassesThroughWhenSuggestionIsInactive() throws {
        let service = KeyboardShortcutService()
        service.configureHandlers(onTab: {}, onAcceptAll: {})
        service.setSuggestionActive(false)

        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 60, keyDown: true))
        event.flags = .maskShift
        XCTAssertNotNil(service.handle(type: .flagsChanged, event: event))
    }

    func testLeftShiftPassesThroughWhenSuggestionIsActive() throws {
        let service = KeyboardShortcutService()
        service.configureHandlers(onTab: {}, onAcceptAll: {})
        service.setSuggestionActive(true)

        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 56, keyDown: true))
        event.flags = .maskShift
        XCTAssertNotNil(service.handle(type: .flagsChanged, event: event))
    }

    func testCommandRightShiftPassesThroughWhenSuggestionIsActive() throws {
        let service = KeyboardShortcutService()
        service.configureHandlers(onTab: {}, onAcceptAll: {})
        service.setSuggestionActive(true)

        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 60, keyDown: true))
        event.flags = [.maskCommand, .maskShift]
        XCTAssertNotNil(service.handle(type: .flagsChanged, event: event))
    }

    func testTabPassesThroughWhenSuggestionIsInactive() throws {
        let service = KeyboardShortcutService()
        service.configureHandlers(onTab: {}, onAcceptAll: {})
        service.setSuggestionActive(false)

        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: true))
        event.flags = []
        let result = service.handle(type: .keyDown, event: event)

        XCTAssertNotNil(result)
    }

    @MainActor
    func testSpaceKeyRecordsSuggestionTriggerWithoutConsumingEvent() async throws {
        let service = KeyboardShortcutService()
        let triggered = expectation(description: "suggestion trigger")
        var capturedEvent: CapturedInputEvent?
        service.configureHandlers(
            onTab: {},
            onAcceptAll: {},
            onSuggestionTriggerKey: { event in
                capturedEvent = event
                triggered.fulfill()
            }
        )
        service.setSuggestionActive(false)

        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true))
        event.flags = []
        let result = service.handle(type: .keyDown, event: event)

        XCTAssertNotNil(result)
        await fulfillment(of: [triggered], timeout: 1)
        XCTAssertEqual(capturedEvent, .text(keyCode: 49, isSuggestionTrigger: true))
    }

    func testCapturedInputEventClassifiesTextNavigationAndDismissalKeyCodes() throws {
        let service = KeyboardShortcutService()

        let backtick = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 50, keyDown: true))
        backtick.flags = []
        XCTAssertEqual(
            service.capturedInputEvent(type: .keyDown, event: backtick),
            .text(keyCode: 50, isSuggestionTrigger: false)
        )

        let commandSpace = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true))
        commandSpace.flags = .maskCommand
        XCTAssertEqual(
            service.capturedInputEvent(type: .keyDown, event: commandSpace),
            .text(keyCode: 49, isSuggestionTrigger: false)
        )

        let escape = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true))
        escape.flags = []
        XCTAssertEqual(service.capturedInputEvent(type: .keyDown, event: escape), .dismissal)

        let leftArrow = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 123, keyDown: true))
        leftArrow.flags = []
        XCTAssertEqual(service.capturedInputEvent(type: .keyDown, event: leftArrow), .navigation(keyCode: 123))
    }

    func testCapturedInputEventClassifiesTabAndModifiedTab() throws {
        let service = KeyboardShortcutService()

        let tab = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: true))
        tab.flags = []
        XCTAssertEqual(service.capturedInputEvent(type: .keyDown, event: tab), .tab)

        let modifiedTab = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: true))
        modifiedTab.flags = .maskShift
        XCTAssertEqual(service.capturedInputEvent(type: .keyDown, event: modifiedTab), .navigation(keyCode: 48))
    }

    func testCapturedInputEventClassifiesRightShiftAndShortcutMutations() throws {
        let service = KeyboardShortcutService()

        let rightShift = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 60, keyDown: true))
        rightShift.flags = .maskShift
        XCTAssertEqual(service.capturedInputEvent(type: .flagsChanged, event: rightShift), .acceptAll)

        let modifiedRightShift = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 60, keyDown: true))
        modifiedRightShift.flags = [.maskCommand, .maskShift]
        XCTAssertEqual(
            service.capturedInputEvent(type: .flagsChanged, event: modifiedRightShift),
            .shortcutMutation(keyCode: 60)
        )

        let leftShift = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 56, keyDown: true))
        leftShift.flags = .maskShift
        XCTAssertEqual(service.capturedInputEvent(type: .flagsChanged, event: leftShift), .shortcutMutation(keyCode: 56))
    }

    func testModifiedTabPassesThroughWhenSuggestionIsActive() throws {
        let service = KeyboardShortcutService()
        service.configureHandlers(onTab: {}, onAcceptAll: {})
        service.setSuggestionActive(true)

        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: true))
        event.flags = .maskShift
        let result = service.handle(type: .keyDown, event: event)

        XCTAssertNotNil(result)
    }

    @MainActor
    func testRapidTabIsConsumedDuringShortcutGraceAfterPresenterTemporarilyHides() async throws {
        let service = KeyboardShortcutService()
        let firstTab = expectation(description: "first tab")
        let secondTab = expectation(description: "second tab")
        var tabCount = 0
        service.configureHandlers(
            onTab: {
                tabCount += 1
                if tabCount == 1 {
                    firstTab.fulfill()
                } else if tabCount == 2 {
                    secondTab.fulfill()
                }
            },
            onAcceptAll: {}
        )
        service.setSuggestionActive(true)

        let firstEvent = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: true))
        firstEvent.flags = []
        XCTAssertNil(service.handle(type: .keyDown, event: firstEvent))
        service.setSuggestionActive(false)

        let secondEvent = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: true))
        secondEvent.flags = []
        XCTAssertNil(service.handle(type: .keyDown, event: secondEvent))

        await fulfillment(of: [firstTab, secondTab], timeout: 1)
    }

    func testClearingShortcutGraceLetsTabPassThroughAfterSuggestionIsExhausted() throws {
        let service = KeyboardShortcutService()
        service.configureHandlers(onTab: {}, onAcceptAll: {})
        service.setSuggestionActive(true)

        let firstEvent = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: true))
        firstEvent.flags = []
        XCTAssertNil(service.handle(type: .keyDown, event: firstEvent))

        service.setSuggestionActive(false)
        service.clearShortcutGrace()

        let secondEvent = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: true))
        secondEvent.flags = []
        XCTAssertNotNil(service.handle(type: .keyDown, event: secondEvent))
    }

    @MainActor
    func testDuplicateTabEventTimestampIsSuppressedWithoutRepeatingHandler() async throws {
        let service = KeyboardShortcutService()
        var tabCount = 0
        service.configureHandlers(
            onTab: {
                tabCount += 1
            },
            onAcceptAll: {}
        )
        service.setSuggestionActive(true)

        let firstEvent = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: true))
        firstEvent.flags = []
        firstEvent.timestamp = 123
        XCTAssertNil(service.handle(type: .keyDown, event: firstEvent))

        let duplicateEvent = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: true))
        duplicateEvent.flags = []
        duplicateEvent.timestamp = 123
        XCTAssertNil(service.handle(type: .keyDown, event: duplicateEvent))

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(tabCount, 1)
    }

    @MainActor
    func testSyntheticSuggestionTriggerIsSuppressedButRealInputFlowsAfterWindow() async throws {
        let clock = KeyboardShortcutTestClock()
        let suppressionController = InputSuppressionController(
            syntheticInputSuppressionInterval: 0.5,
            now: { clock.now }
        )
        let service = KeyboardShortcutService(inputSuppressionController: suppressionController)
        var capturedEvents: [CapturedInputEvent] = []
        service.configureHandlers(
            onTab: {},
            onAcceptAll: {},
            onSuggestionTriggerKey: { event in
                capturedEvents.append(event)
            }
        )

        let syntheticSpace = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true))
        syntheticSpace.flags = []
        suppressionController.recordSyntheticInput()
        XCTAssertNotNil(service.handle(type: .keyDown, event: syntheticSpace))

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(capturedEvents, [])

        clock.advance(by: 0.6)
        let realSpace = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true))
        realSpace.flags = []
        XCTAssertNotNil(service.handle(type: .keyDown, event: realSpace))

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(capturedEvents, [.text(keyCode: 49, isSuggestionTrigger: true)])
    }
}

private final class KeyboardShortcutTestClock {
    private(set) var now = Date(timeIntervalSince1970: 2_000)

    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }
}
