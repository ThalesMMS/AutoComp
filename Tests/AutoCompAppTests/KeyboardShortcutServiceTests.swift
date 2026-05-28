import AppKit
import AutoCompCore
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

    @MainActor
    func testConsumedConfiguredShortcutsDoNotLeakKeyDownOrReleaseAndRunOnce() async throws {
        for leakCase in ShortcutLeakCase.consumedDefaults {
            let service = KeyboardShortcutService()
            var commands: [KeyboardShortcutCommand] = []
            service.configureHandlers(
                onCommand: { command in
                    commands.append(command)
                },
                shouldInterceptCommand: { command in
                    switch command {
                    case .selectPreviousSuggestion, .selectNextSuggestion:
                        return leakCase.popupVisible
                    case .acceptNextWord, .acceptFullSuggestion, .manualTrigger, .dismissSuggestion, .toggleAutocomplete:
                        return true
                    }
                }
            )
            service.setSuggestionActive(leakCase.suggestionActive)

            let press = try leakCase.makePressEvent()
            XCTAssertNil(
                service.handle(type: leakCase.pressType, event: press),
                "\(leakCase.command.rawValue) key press should be consumed"
            )

            let release = try leakCase.makeReleaseEvent()
            XCTAssertNil(
                service.handle(type: leakCase.releaseType, event: release),
                "\(leakCase.command.rawValue) release should be consumed after the shortcut press"
            )

            try await waitForShortcutDispatch()
            XCTAssertEqual(commands, [leakCase.command], "\(leakCase.command.rawValue) should dispatch exactly once")
        }
    }

    @MainActor
    func testConfiguredShortcutsPassThroughWhenInterceptionDeclinesCommand() async throws {
        for command in KeyboardShortcutCommand.allCases {
            let leakCase = ShortcutLeakCase(command: command, suggestionActive: true)
            let service = KeyboardShortcutService()
            var commands: [KeyboardShortcutCommand] = []
            service.configureHandlers(
                onCommand: { command in
                    commands.append(command)
                },
                shouldInterceptCommand: { _ in false }
            )
            service.setSuggestionActive(true)

            let press = try leakCase.makePressEvent()
            XCTAssertNotNil(
                service.handle(type: leakCase.pressType, event: press),
                "\(command.rawValue) key press should pass through when interception is declined"
            )

            let release = try leakCase.makeReleaseEvent()
            XCTAssertNotNil(
                service.handle(type: leakCase.releaseType, event: release),
                "\(command.rawValue) release should pass through when the press was not consumed"
            )

            try await waitForShortcutDispatch()
            XCTAssertEqual(commands, [], "\(command.rawValue) should not dispatch when passed through")
        }
    }

    @MainActor
    func testSuggestionScopedShortcutsPassThroughWhenNoSuggestionIsArmed() async throws {
        for command in ShortcutLeakCase.suggestionScopedCommands {
            let leakCase = ShortcutLeakCase(command: command, suggestionActive: false, popupVisible: false)
            let service = KeyboardShortcutService()
            var commands: [KeyboardShortcutCommand] = []
            service.configureHandlers(
                onCommand: { command in
                    commands.append(command)
                }
            )
            service.setSuggestionActive(false)

            let press = try leakCase.makePressEvent()
            XCTAssertNotNil(
                service.handle(type: leakCase.pressType, event: press),
                "\(command.rawValue) key press should pass through without an armed suggestion"
            )

            let release = try leakCase.makeReleaseEvent()
            XCTAssertNotNil(
                service.handle(type: leakCase.releaseType, event: release),
                "\(command.rawValue) release should pass through when the press was not consumed"
            )

            try await waitForShortcutDispatch()
            XCTAssertEqual(commands, [], "\(command.rawValue) should not dispatch without an armed suggestion")
        }
    }

    @MainActor
    func testRightShiftReleaseSuppressionIsConsumedOnceSoPassThroughShiftCannotGetStuck() async throws {
        let service = KeyboardShortcutService()
        var commands: [KeyboardShortcutCommand] = []
        service.configureHandlers(
            onCommand: { command in
                commands.append(command)
            }
        )
        service.setSuggestionActive(true)

        let consumedPress = try ShortcutLeakCase.acceptFullSuggestion.makePressEvent()
        XCTAssertNil(service.handle(type: .flagsChanged, event: consumedPress))

        let consumedRelease = try ShortcutLeakCase.acceptFullSuggestion.makeReleaseEvent()
        XCTAssertNil(service.handle(type: .flagsChanged, event: consumedRelease))

        service.setSuggestionActive(false)
        service.clearShortcutGrace()

        let passThroughPress = try ShortcutLeakCase.acceptFullSuggestion.makePressEvent()
        XCTAssertNotNil(service.handle(type: .flagsChanged, event: passThroughPress))

        let passThroughRelease = try ShortcutLeakCase.acceptFullSuggestion.makeReleaseEvent()
        XCTAssertNotNil(service.handle(type: .flagsChanged, event: passThroughRelease))

        try await waitForShortcutDispatch()
        XCTAssertEqual(commands, [.acceptFullSuggestion])
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
    func testAlternativeSelectionShortcutsAreConsumedOnlyWhenPopupIsAvailable() async throws {
        let service = KeyboardShortcutService()
        var popupAvailable = false
        var commands: [KeyboardShortcutCommand] = []
        service.configureHandlers(
            onCommand: { command in
                commands.append(command)
            },
            shouldInterceptCommand: { command in
                switch command {
                case .selectPreviousSuggestion, .selectNextSuggestion:
                    return popupAvailable
                case .acceptNextWord, .acceptFullSuggestion, .manualTrigger, .dismissSuggestion, .toggleAutocomplete:
                    return true
                }
            }
        )
        service.setSuggestionActive(true)

        let firstNext = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 30, keyDown: true))
        firstNext.flags = .maskAlternate
        XCTAssertNotNil(service.handle(type: .keyDown, event: firstNext))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(commands, [])

        popupAvailable = true
        let secondNext = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 30, keyDown: true))
        secondNext.flags = .maskAlternate
        XCTAssertNil(service.handle(type: .keyDown, event: secondNext))

        let previous = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 33, keyDown: true))
        previous.flags = .maskAlternate
        XCTAssertNil(service.handle(type: .keyDown, event: previous))

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(commands, [.selectNextSuggestion, .selectPreviousSuggestion])
    }

    @MainActor
    func testManualTriggerShortcutRunsWithoutActiveSuggestion() async throws {
        let service = KeyboardShortcutService()
        let triggered = expectation(description: "manual trigger")
        service.configureHandlers(
            onCommand: { command in
                XCTAssertEqual(command, .manualTrigger)
                triggered.fulfill()
            }
        )

        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true))
        event.flags = .maskAlternate
        let result = service.handle(type: .keyDown, event: event)

        XCTAssertNil(result)
        await fulfillment(of: [triggered], timeout: 1)
    }

    @MainActor
    func testDismissShortcutRequiresActiveSuggestion() async throws {
        let service = KeyboardShortcutService()
        var commands: [KeyboardShortcutCommand] = []
        service.configureHandlers(
            onCommand: { command in
                commands.append(command)
            }
        )

        let inactiveEscape = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true))
        inactiveEscape.flags = []
        XCTAssertNotNil(service.handle(type: .keyDown, event: inactiveEscape))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(commands, [])

        service.setSuggestionActive(true)
        let activeEscape = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true))
        activeEscape.flags = []
        XCTAssertNil(service.handle(type: .keyDown, event: activeEscape))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(commands, [.dismissSuggestion])
    }

    @MainActor
    func testCustomAcceptNextWordShortcutConsumesConfiguredKey() async throws {
        var settings = KeyboardShortcutSettings.defaults
        settings[.acceptNextWord] = KeyboardShortcutBinding(keyCode: 50)
        let service = KeyboardShortcutService(shortcutSettings: settings)
        let accepted = expectation(description: "accept next word")
        service.configureHandlers(
            onCommand: { command in
                XCTAssertEqual(command, .acceptNextWord)
                accepted.fulfill()
            }
        )
        service.setSuggestionActive(true)

        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 50, keyDown: true))
        event.flags = []
        let result = service.handle(type: .keyDown, event: event)

        XCTAssertNil(result)
        await fulfillment(of: [accepted], timeout: 1)
    }

    @MainActor
    func testTabPassesThroughWhileInputMethodIsComposing() async throws {
        let service = KeyboardShortcutService(
            inputMethodStateProvider: {
                InputMethodState(
                    isASCIICompatible: true,
                    isComposingText: true,
                    currentInputSourceID: "com.apple.keylayout.US"
                )
            }
        )
        var tabCount = 0
        service.configureHandlers(
            onTab: {
                tabCount += 1
            },
            onAcceptAll: {}
        )
        service.setSuggestionActive(true)

        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: true))
        event.flags = []
        let result = service.handle(type: .keyDown, event: event)

        XCTAssertNotNil(result)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(tabCount, 0)
    }

    @MainActor
    func testSpaceKeyRecordsSuggestionTriggerWithoutConsumingEvent() async throws {
        let service = KeyboardShortcutService()
        let triggered = expectation(description: "suggestion trigger")
        var capturedEvent: CapturedInputEvent?
        service.configureHandlers(
            onTab: {},
            onAcceptAll: {},
            onInputEvent: { event in
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

    @MainActor
    func testSpaceKeyDoesNotRecordSuggestionTriggerForNonASCIIInputSource() async throws {
        let service = KeyboardShortcutService(
            inputMethodStateProvider: {
                InputMethodState(
                    isASCIICompatible: false,
                    currentInputSourceID: "com.apple.inputmethod.example"
                )
            }
        )
        var capturedEvents: [CapturedInputEvent] = []
        service.configureHandlers(
            onTab: {},
            onAcceptAll: {},
            onInputEvent: { event in
                capturedEvents.append(event)
            }
        )
        service.setSuggestionActive(false)

        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true))
        event.flags = []
        let result = service.handle(type: .keyDown, event: event)

        XCTAssertNotNil(result)
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(capturedEvents, [])
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
            .shortcutMutation(keyCode: 49)
        )

        let escape = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true))
        escape.flags = []
        XCTAssertEqual(service.capturedInputEvent(type: .keyDown, event: escape), .dismissal)

        let leftArrow = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 123, keyDown: true))
        leftArrow.flags = []
        XCTAssertEqual(service.capturedInputEvent(type: .keyDown, event: leftArrow), .navigation(keyCode: 123))
    }

    func testCapturedInputEventClassifiesMouseDownAsPointerReset() throws {
        let service = KeyboardShortcutService()
        let click = try XCTUnwrap(
            CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: .zero,
                mouseButton: .left
            )
        )

        XCTAssertEqual(service.capturedInputEvent(type: .leftMouseDown, event: click), .pointer)
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

    func testCapturedInputEventSchedulingAndClearingSemantics() {
        let normalText = CapturedInputEvent.text(keyCode: 0, isSuggestionTrigger: false)
        let triggerText = CapturedInputEvent.text(keyCode: CapturedInputEventAdapter.spaceKeyCode, isSuggestionTrigger: true)
        let deleteText = CapturedInputEvent.text(keyCode: 51, isSuggestionTrigger: false)

        XCTAssertTrue(normalText.shouldSchedulePrediction)
        XCTAssertTrue(triggerText.shouldSchedulePrediction)
        XCTAssertFalse(deleteText.shouldSchedulePrediction)

        XCTAssertFalse(normalText.shouldClearSuggestion)
        XCTAssertFalse(triggerText.shouldClearSuggestion)
        XCTAssertTrue(deleteText.shouldClearSuggestion)
        XCTAssertTrue(CapturedInputEvent.navigation(keyCode: 123).shouldClearSuggestion)
        XCTAssertTrue(CapturedInputEvent.dismissal.shouldClearSuggestion)
        XCTAssertTrue(CapturedInputEvent.shortcutMutation(keyCode: 56).shouldClearSuggestion)
        XCTAssertTrue(CapturedInputEvent.pointer.shouldClearSuggestion)
        XCTAssertFalse(CapturedInputEvent.tab.shouldClearSuggestion)
        XCTAssertFalse(CapturedInputEvent.acceptAll.shouldClearSuggestion)
        XCTAssertFalse(CapturedInputEvent.pointer.shouldSchedulePrediction)
    }

    @MainActor
    func testTextNavigationAndShortcutMutationForwardAsInputEvents() async throws {
        let service = KeyboardShortcutService()
        var capturedEvents: [CapturedInputEvent] = []
        service.configureHandlers(
            onTab: {},
            onAcceptAll: {},
            onInputEvent: { event in
                capturedEvents.append(event)
            }
        )

        let text = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 50, keyDown: true))
        text.flags = []
        XCTAssertNotNil(service.handle(type: .keyDown, event: text))

        let navigation = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 123, keyDown: true))
        navigation.flags = []
        XCTAssertNotNil(service.handle(type: .keyDown, event: navigation))

        let modifier = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 56, keyDown: true))
        modifier.flags = .maskShift
        XCTAssertNotNil(service.handle(type: .flagsChanged, event: modifier))

        let click = try XCTUnwrap(
            CGEvent(
                mouseEventSource: nil,
                mouseType: .leftMouseDown,
                mouseCursorPosition: .zero,
                mouseButton: .left
            )
        )
        XCTAssertNotNil(service.handle(type: .leftMouseDown, event: click))

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(capturedEvents, [
            .text(keyCode: 50, isSuggestionTrigger: false),
            .navigation(keyCode: 123),
            .shortcutMutation(keyCode: 56),
            .pointer
        ])
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
    func testSyntheticSuggestionTriggerIsSuppressedButRealInputFlowsAfterBudget() async throws {
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
            onInputEvent: { event in
                capturedEvents.append(event)
            }
        )

        let syntheticSpace = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true))
        syntheticSpace.flags = []
        let syntheticSpaceRelease = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: false))
        syntheticSpaceRelease.flags = []
        suppressionController.registerSyntheticInsertion(expectedKeyDownCount: 1, expectedKeyUpCount: 1)
        XCTAssertNotNil(service.handle(type: .keyDown, event: syntheticSpace))
        XCTAssertNotNil(service.handle(type: .keyUp, event: syntheticSpaceRelease))

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(capturedEvents, [])

        let realSpace = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true))
        realSpace.flags = []
        XCTAssertNotNil(service.handle(type: .keyDown, event: realSpace))

        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(capturedEvents, [.text(keyCode: 49, isSuggestionTrigger: true)])
    }

    @MainActor
    private func waitForShortcutDispatch() async throws {
        try await Task.sleep(nanoseconds: 50_000_000)
    }
}

private struct ShortcutLeakCase {
    let command: KeyboardShortcutCommand
    let suggestionActive: Bool
    let popupVisible: Bool

    init(
        command: KeyboardShortcutCommand,
        suggestionActive: Bool,
        popupVisible: Bool = false
    ) {
        self.command = command
        self.suggestionActive = suggestionActive
        self.popupVisible = popupVisible
    }

    static let acceptFullSuggestion = ShortcutLeakCase(
        command: .acceptFullSuggestion,
        suggestionActive: true
    )

    static let suggestionScopedCommands: [KeyboardShortcutCommand] = [
        .acceptNextWord,
        .acceptFullSuggestion,
        .dismissSuggestion,
        .selectNextSuggestion,
        .selectPreviousSuggestion
    ]

    static let consumedDefaults: [ShortcutLeakCase] = [
        ShortcutLeakCase(command: .acceptNextWord, suggestionActive: true),
        ShortcutLeakCase(command: .acceptFullSuggestion, suggestionActive: true),
        ShortcutLeakCase(command: .manualTrigger, suggestionActive: false),
        ShortcutLeakCase(command: .dismissSuggestion, suggestionActive: true),
        ShortcutLeakCase(command: .toggleAutocomplete, suggestionActive: false),
        ShortcutLeakCase(command: .selectNextSuggestion, suggestionActive: true, popupVisible: true),
        ShortcutLeakCase(command: .selectPreviousSuggestion, suggestionActive: true, popupVisible: true)
    ]

    private var binding: KeyboardShortcutBinding {
        KeyboardShortcutSettings.defaults[command]
    }

    var pressType: CGEventType {
        switch binding.trigger {
        case .keyDown:
            return .keyDown
        case .flagsChanged:
            return .flagsChanged
        }
    }

    var releaseType: CGEventType {
        switch binding.trigger {
        case .keyDown:
            return .keyUp
        case .flagsChanged:
            return .flagsChanged
        }
    }

    func makePressEvent() throws -> CGEvent {
        try makeEvent(keyDown: true, flags: binding.modifiers.cgEventFlags)
    }

    func makeReleaseEvent() throws -> CGEvent {
        let releaseFlags: CGEventFlags = binding.trigger == .flagsChanged ? [] : binding.modifiers.cgEventFlags
        return try makeEvent(keyDown: false, flags: releaseFlags)
    }

    private func makeEvent(keyDown: Bool, flags: CGEventFlags) throws -> CGEvent {
        let event = try XCTUnwrap(
            CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(binding.keyCode), keyDown: keyDown)
        )
        event.flags = flags
        return event
    }
}

private final class KeyboardShortcutTestClock {
    private(set) var now = Date(timeIntervalSince1970: 2_000)

    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }
}
