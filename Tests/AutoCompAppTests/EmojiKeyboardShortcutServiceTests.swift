import AppKit
@testable import AutoCompApp
import XCTest

final class EmojiKeyboardShortcutServiceTests: XCTestCase {
    func testActiveEmojiPickerConsumesTabEscapeAndArrows() throws {
        let service = KeyboardShortcutService()
        var commands: [EmojiKeyboardCommand] = []
        let expectation = expectation(description: "emoji commands")
        expectation.expectedFulfillmentCount = 4
        service.configureHandlers(
            onCommand: { _ in },
            onEmojiCommand: { command in
                commands.append(command)
                expectation.fulfill()
            }
        )
        service.setEmojiPickerActive(true)

        XCTAssertNil(service.handle(type: .keyDown, event: try keyDown(CapturedInputEventAdapter.tabKeyCode)))
        XCTAssertNil(service.handle(type: .keyDown, event: try keyDown(CapturedInputEventAdapter.escapeKeyCode)))
        XCTAssertNil(service.handle(type: .keyDown, event: try keyDown(125)))
        XCTAssertNil(service.handle(type: .keyDown, event: try keyDown(126)))

        wait(for: [expectation], timeout: 1.0)
        XCTAssertEqual(commands, [.acceptSelected, .cancel, .selectNext, .selectPrevious])
    }

    func testInactiveEmojiPickerLeavesNavigationAndTextEventsAlone() throws {
        let service = KeyboardShortcutService()
        var emojiCommands: [EmojiKeyboardCommand] = []
        var inputEvents: [CapturedInputEvent] = []
        service.configureHandlers(
            onCommand: { _ in },
            onInputEvent: { inputEvents.append($0) },
            onEmojiCommand: { emojiCommands.append($0) }
        )

        let downArrow = try keyDown(125)
        let text = try keyDown(0)
        let escape = try keyDown(CapturedInputEventAdapter.escapeKeyCode)

        XCTAssertNotNil(service.handle(type: .keyDown, event: downArrow))
        XCTAssertNotNil(service.handle(type: .keyDown, event: text))
        XCTAssertNotNil(service.handle(type: .keyDown, event: escape))

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertTrue(emojiCommands.isEmpty)
        XCTAssertEqual(inputEvents, [
            .navigation(keyCode: 125),
            .text(keyCode: 0, isSuggestionTrigger: false)
        ])
    }

    func testActiveEmojiPickerStillLetsOrdinaryTextPassThroughForQueryUpdates() throws {
        let service = KeyboardShortcutService()
        var inputEvents: [CapturedInputEvent] = []
        service.configureHandlers(
            onCommand: { _ in },
            onInputEvent: { inputEvents.append($0) },
            onEmojiCommand: { _ in XCTFail("Text should not dispatch emoji keyboard commands") }
        )
        service.setEmojiPickerActive(true)

        let text = try keyDown(0)

        XCTAssertNotNil(service.handle(type: .keyDown, event: text))

        RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        XCTAssertEqual(inputEvents, [.text(keyCode: 0, isSuggestionTrigger: false)])
    }

    func testSingleResultMacroConsumesTabButCancelsAndPassesArrowThrough() throws {
        let service = KeyboardShortcutService()
        var commands: [EmojiKeyboardCommand] = []
        service.configureHandlers(onCommand: { _ in }, onEmojiCommand: { commands.append($0) })
        service.setInlineCommandState(active: true, capabilities: .singleResult)

        XCTAssertNil(service.handle(type: .keyDown, event: try keyDown(CapturedInputEventAdapter.tabKeyCode)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(commands, [.acceptSelected])

        service.setInlineCommandState(active: true, capabilities: .singleResult)
        XCTAssertNotNil(service.handle(type: .keyDown, event: try keyDown(125)))
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        XCTAssertEqual(commands, [.acceptSelected, .cancel])
    }

    private func keyDown(_ keyCode: UInt16, flags: CGEventFlags = []) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(keyCode), keyDown: true))
        event.flags = flags
        return event
    }
}
