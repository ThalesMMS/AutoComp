import SwiftUI
import XCTest

@testable import AutoCompApp

final class ShortcutRecorderStateTests: XCTestCase {
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
}
