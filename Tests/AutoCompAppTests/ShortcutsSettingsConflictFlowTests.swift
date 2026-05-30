import AppKit
@testable import AutoCompApp
import XCTest

final class ShortcutsSettingsConflictFlowTests: XCTestCase {
    func testProposingConflictingBindingIsRejectedAndReturnsOwnerCommand() {
        var settings = KeyboardShortcutSettings.defaults

        // Pick a known default binding that exists on another command.
        let existingOwner: KeyboardShortcutCommand = .manualTrigger
        let proposedCommand: KeyboardShortcutCommand = .dismissSuggestion
        let conflictingBinding = settings[existingOwner]

        XCTAssertNotEqual(existingOwner, proposedCommand)

        switch settings.proposingUpdate(command: proposedCommand, binding: conflictingBinding) {
        case .success:
            XCTFail("Expected conflicting binding proposal to be rejected")

        case .failure(let rejection):
            XCTAssertEqual(rejection.command, proposedCommand)
            switch rejection.reason {
            case .duplicateShortcut(let conflictsWith):
                XCTAssertEqual(conflictsWith, existingOwner)
            case .reservedShortcut:
                XCTFail("Expected duplicateShortcut rejection, got reservedShortcut")
            }
        }

        // Ensure the current settings were not mutated.
        XCTAssertEqual(settings[proposedCommand], KeyboardShortcutSettings.defaults[proposedCommand])
    }
}
