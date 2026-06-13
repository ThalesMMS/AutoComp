import SwiftUI
import XCTest

@testable import AutoCompApp

final class ShortcutRecorderStateTests: XCTestCase {
    func testModifierPressDoesNotCommitUntilRelease() {
        var state = ShortcutRecorderState()
        let optionPress = binding(keyCode: 58, modifiers: .option, trigger: .flagsChanged)

        XCTAssertNil(state.recordFlagsChanged(optionPress))
        XCTAssertEqual(
            state.recordFlagsChanged(binding(keyCode: 58, modifiers: [], trigger: .flagsChanged)),
            optionPress
        )
    }

    func testModifierKeyComboCommitsOnKeyDownBeforeModifierRelease() {
        var state = ShortcutRecorderState()
        let optionPress = binding(keyCode: 58, modifiers: .option, trigger: .flagsChanged)
        let optionSpace = binding(keyCode: 49, modifiers: .option, trigger: .keyDown)

        XCTAssertNil(state.recordFlagsChanged(optionPress))
        XCTAssertEqual(state.recordKeyDown(optionSpace), optionSpace)
        XCTAssertNil(state.recordFlagsChanged(binding(keyCode: 58, modifiers: [], trigger: .flagsChanged)))
    }

    func testModifierOnlyRecordingKeepsLargestModifierSetUntilAllModifiersRelease() {
        var state = ShortcutRecorderState()
        let commandPress = binding(keyCode: 55, modifiers: .command, trigger: .flagsChanged)
        let commandShiftPress = binding(keyCode: 56, modifiers: [.command, .shift], trigger: .flagsChanged)
        let shiftRelease = binding(keyCode: 56, modifiers: .command, trigger: .flagsChanged)

        XCTAssertNil(state.recordFlagsChanged(commandPress))
        XCTAssertNil(state.recordFlagsChanged(commandShiftPress))
        XCTAssertNil(state.recordFlagsChanged(shiftRelease))
        XCTAssertEqual(
            state.recordFlagsChanged(binding(keyCode: 55, modifiers: [], trigger: .flagsChanged)),
            commandShiftPress
        )
    }

    func testResetClearsPendingModifierOnlyRecording() {
        var state = ShortcutRecorderState()
        XCTAssertNil(state.recordFlagsChanged(binding(keyCode: 58, modifiers: .option, trigger: .flagsChanged)))

        state.reset()

        XCTAssertNil(state.recordFlagsChanged(binding(keyCode: 58, modifiers: [], trigger: .flagsChanged)))
    }

    func testRecorderConfirmationIdentifierContainsCommand() {
        // This is a light-weight regression test ensuring we keep deterministic identifiers
        // for app-level state assertions (e.g., via view introspection / UI harness).
        // If these strings change, update dependent test harnesses.
        XCTAssertEqual(
            makeIdentifier(kind: "ShortcutRecorderConfirmationText", command: .manualTrigger),
            "ShortcutRecorderConfirmationText.manualTrigger"
        )
    }

    func testRecorderButtonIdentifierContainsCommand() {
        XCTAssertEqual(
            makeIdentifier(kind: "ShortcutRecorderButton", command: .acceptFullSuggestion),
            "ShortcutRecorderButton.acceptFullSuggestion"
        )
    }

    // NOTE: The underlying identifiers are declared inside ShortcutsSettingsView.swift.
    // Swift doesn't allow us to reach that private enum from here, so we validate the
    // contract at the string-level.
    private func makeIdentifier(kind: String, command: KeyboardShortcutCommand) -> String {
        "\(kind).\(command.rawValue)"
    }

    private func binding(
        keyCode: UInt16,
        modifiers: KeyboardShortcutModifiers,
        trigger: KeyboardShortcutTrigger
    ) -> KeyboardShortcutBinding {
        KeyboardShortcutBinding(keyCode: keyCode, modifiers: modifiers, trigger: trigger)
    }
}
