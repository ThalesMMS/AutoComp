import XCTest

#if canImport(AutoCompApp)
@testable import AutoCompApp

final class OverlayShortcutHintsProviderTests: XCTestCase {
    func testHintsFormatsExpectedBindings() {
        // Arrange: use a deterministic formatter that makes it obvious which binding was passed.
        let provider = OverlayShortcutHintsProvider { binding in
            "kc:\(binding.keyCode)|m:\(binding.modifiers.rawValue)|t:\(binding.trigger)"
        }

        let settings = KeyboardShortcutSettings(
            acceptNextWord: KeyboardShortcutBinding(keyCode: 48),
            acceptFullSuggestion: KeyboardShortcutBinding(keyCode: 36, modifiers: [.command]),
            selectPreviousSuggestion: KeyboardShortcutBinding(keyCode: 123),
            selectNextSuggestion: KeyboardShortcutBinding(keyCode: 124),
            manualTrigger: KeyboardShortcutBinding(keyCode: 49, modifiers: [.option]),
            dismissSuggestion: KeyboardShortcutBinding(keyCode: 53),
            toggleAutocomplete: KeyboardShortcutBinding(keyCode: 11, modifiers: [.control])
        )

        // Act
        let hints = provider.hints(from: settings)

        // Assert
        XCTAssertEqual(hints.acceptNextWord, "kc:48|m:0|t:keyDown")
        XCTAssertEqual(hints.acceptFullSuggestion, "kc:36|m:1|t:keyDown")
        XCTAssertEqual(hints.previousSuggestion, "kc:123|m:0|t:keyDown")
        XCTAssertEqual(hints.nextSuggestion, "kc:124|m:0|t:keyDown")
        XCTAssertEqual(hints.dismissSuggestion, "kc:53|m:0|t:keyDown")
    }
}
#endif
