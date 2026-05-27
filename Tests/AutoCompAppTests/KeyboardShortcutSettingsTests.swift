import AppKit
@testable import AutoCompApp
import XCTest

final class KeyboardShortcutSettingsTests: XCTestCase {
    func testStoreRoundTripsCustomBindings() {
        let defaultsName = "KeyboardShortcutSettingsTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
        }
        let store = KeyboardShortcutSettingsStore(defaults: defaults)
        var settings = KeyboardShortcutSettings.defaults
        settings[.manualTrigger] = KeyboardShortcutBinding(
            keyCode: 17,
            modifiers: [.command, .option]
        )

        store.save(settings)

        XCTAssertEqual(store.load(), settings)
    }

    func testMatchingRequiresConfiguredKeyCodeAndModifiers() throws {
        var settings = KeyboardShortcutSettings.defaults
        settings[.manualTrigger] = KeyboardShortcutBinding(
            keyCode: CapturedInputEventAdapter.spaceKeyCode,
            modifiers: [.command, .option, .control, .shift]
        )

        let matchingEvent = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true))
        matchingEvent.flags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        XCTAssertEqual(settings.command(matching: .keyDown, event: matchingEvent), .manualTrigger)

        let missingModifierEvent = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true))
        missingModifierEvent.flags = [.maskCommand, .maskAlternate, .maskControl]
        XCTAssertNil(settings.command(matching: .keyDown, event: missingModifierEvent))

        let wrongShortcutModifierEvent = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true))
        wrongShortcutModifierEvent.flags = [.maskCommand, .maskAlternate, .maskShift]
        XCTAssertNil(settings.command(matching: .keyDown, event: wrongShortcutModifierEvent))

        settings[.manualTrigger] = KeyboardShortcutBinding(
            keyCode: CapturedInputEventAdapter.spaceKeyCode,
            modifiers: [.command, .option]
        )

        let extraRecognizedModifierEvent = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true))
        extraRecognizedModifierEvent.flags = [.maskCommand, .maskAlternate, .maskControl]
        XCTAssertNil(settings.command(matching: .keyDown, event: extraRecognizedModifierEvent))
    }

    func testDefaultsMatchAcceptanceDismissManualAndToggleCommands() throws {
        let settings = KeyboardShortcutSettings.defaults

        let tab = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 48, keyDown: true))
        tab.flags = []
        XCTAssertEqual(settings.command(matching: .keyDown, event: tab), .acceptNextWord)

        let rightShift = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 60, keyDown: true))
        rightShift.flags = .maskShift
        XCTAssertEqual(settings.command(matching: .flagsChanged, event: rightShift), .acceptFullSuggestion)

        let optionSpace = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 49, keyDown: true))
        optionSpace.flags = .maskAlternate
        XCTAssertEqual(settings.command(matching: .keyDown, event: optionSpace), .manualTrigger)

        let escape = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 53, keyDown: true))
        escape.flags = []
        XCTAssertEqual(settings.command(matching: .keyDown, event: escape), .dismissSuggestion)

        let downArrow = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 125, keyDown: true))
        downArrow.flags = []
        XCTAssertNil(settings.command(matching: .keyDown, event: downArrow))

        let upArrow = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 126, keyDown: true))
        upArrow.flags = []
        XCTAssertNil(settings.command(matching: .keyDown, event: upArrow))

        let toggle = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true))
        toggle.flags = [.maskCommand, .maskAlternate, .maskControl]
        XCTAssertEqual(settings.command(matching: .keyDown, event: toggle), .toggleAutocomplete)
    }
}
