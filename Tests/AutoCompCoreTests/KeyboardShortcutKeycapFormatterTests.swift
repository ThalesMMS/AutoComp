import XCTest
@testable import AutoCompCore

final class KeyboardShortcutKeycapFormatterTests: XCTestCase {
    func testFormat_TabKeyProducesTabSymbol() {
        let binding = KeyboardShortcutKeycapFormatter.Binding(keyCode: KeyboardShortcutKeycapFormatter.KnownKeyCodes.tab)
        XCTAssertEqual(KeyboardShortcutKeycapFormatter.format(binding), "⇥")
    }

    func testFormat_CommandReturnProducesCmdReturnSymbols() {
        let binding = KeyboardShortcutKeycapFormatter.Binding(
            keyCode: KeyboardShortcutKeycapFormatter.KnownKeyCodes.returnKey,
            modifiers: [.command]
        )
        XCTAssertEqual(KeyboardShortcutKeycapFormatter.format(binding), "⌘↩")
    }

    func testFormat_RightShiftFlagsChangedUsesRightShiftLabel() {
        let binding = KeyboardShortcutKeycapFormatter.Binding(
            keyCode: KeyboardShortcutKeycapFormatter.KnownKeyCodes.rightShift,
            modifiers: [.shift],
            trigger: .flagsChanged
        )
        XCTAssertEqual(KeyboardShortcutKeycapFormatter.format(binding), "Right ⇧")
    }

    func testFormat_UnknownKeyCodeFallsBackToStableLabel() {
        let binding = KeyboardShortcutKeycapFormatter.Binding(keyCode: 4242)
        XCTAssertEqual(KeyboardShortcutKeycapFormatter.format(binding), "Key 4242")
    }
}
