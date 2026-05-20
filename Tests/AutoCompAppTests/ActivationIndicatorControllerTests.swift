import AppKit
import AutoCompCore
@testable import AutoCompApp
import XCTest

@MainActor
final class ActivationIndicatorControllerTests: XCTestCase {
    func testPanelDoesNotActivateOrTakeInput() {
        let panel = ActivationIndicatorController.makePanel()

        XCTAssertTrue(panel.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertFalse(panel.isOpaque)
        XCTAssertFalse(panel.hasShadow)
    }

    func testHiddenAndDisabledModesDoNotShowIndicator() {
        XCTAssertNil(ActivationIndicatorController.placement(
            mode: .hidden,
            displayMode: .inline,
            context: context()
        ))
        XCTAssertNil(ActivationIndicatorController.placement(
            mode: .caretAnchor,
            displayMode: .disabled,
            context: context()
        ))
    }

    func testCaretAnchorPlacementUsesCaretRect() {
        let placement = ActivationIndicatorController.placement(
            mode: .caretAnchor,
            displayMode: .inline,
            context: context(caretRect: CGRect(x: 100, y: 200, width: 2, height: 20))
        )

        XCTAssertEqual(
            placement,
            ActivationIndicatorPlacement(
                frame: CGRect(x: 106, y: 206, width: 8, height: 8),
                mode: .caretAnchor
            )
        )
    }

    func testFieldEdgePlacementUsesFocusedElementRect() {
        let placement = ActivationIndicatorController.placement(
            mode: .fieldEdge,
            displayMode: .mirrorWindow,
            context: context(
                caretRect: CGRect(x: 100, y: 200, width: 2, height: 20),
                focusedElementRect: CGRect(x: 80, y: 180, width: 260, height: 44)
            )
        )

        XCTAssertEqual(
            placement,
            ActivationIndicatorPlacement(
                frame: CGRect(x: 326, y: 186, width: 8, height: 8),
                mode: .fieldEdge
            )
        )
    }

    func testSelectionOrMissingAnchorHidesIndicator() {
        XCTAssertNil(ActivationIndicatorController.placement(
            mode: .caretAnchor,
            displayMode: .inline,
            context: context(caretRect: nil)
        ))
        XCTAssertNil(ActivationIndicatorController.placement(
            mode: .caretAnchor,
            displayMode: .inline,
            context: context(selectedRange: NSRange(location: 3, length: 2))
        ))
    }

    private func context(
        caretRect: CGRect? = CGRect(x: 100, y: 200, width: 2, height: 20),
        focusedElementRect: CGRect? = nil,
        selectedRange: NSRange? = NSRange(location: 5, length: 0)
    ) -> TextContext {
        TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: "Hello",
            selectedRange: selectedRange,
            caretRect: caretRect,
            focusedElementRect: focusedElementRect
        )
    }
}
