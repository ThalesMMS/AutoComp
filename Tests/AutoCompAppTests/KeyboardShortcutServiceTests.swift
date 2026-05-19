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
        service.configureHandlers(
            onTab: {},
            onAcceptAll: {},
            onSuggestionTriggerKey: {
                triggered.fulfill()
            }
        )
        service.setSuggestionActive(false)

        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true))
        event.flags = []
        let result = service.handle(type: .keyDown, event: event)

        XCTAssertNotNil(result)
        await fulfillment(of: [triggered], timeout: 1)
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
}
