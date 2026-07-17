import AutoCompCore
@testable import AutoCompApp
import XCTest

@MainActor
final class VisualInlineOverlayPresenterTests: XCTestCase {
    func testCanPresentTrustedCaretOnSecondaryDisplay() {
        let presenter = presenter()
        let context = textContext(
            caretRect: CGRect(x: 10_050, y: 110, width: 2, height: 18),
            focusedElementRect: CGRect(x: 10_020, y: 90, width: 420, height: 56)
        )

        XCTAssertTrue(presenter.canPresent(suggestion(), for: context))
    }

    func testCanPresentRejectsCaretOutsideInjectedScreens() {
        let presenter = presenter()
        let context = textContext(
            caretRect: CGRect(x: 12_000, y: 110, width: 2, height: 18),
            focusedElementRect: CGRect(x: 10_020, y: 90, width: 420, height: 56)
        )

        XCTAssertFalse(presenter.canPresent(suggestion(), for: context))
    }

    func testCanPresentRejectsMissingScreenContext() {
        let presenter = presenter(screenContextProvider: { _ in nil })
        let context = textContext(
            caretRect: CGRect(x: 100, y: 110, width: 2, height: 18),
            focusedElementRect: CGRect(x: 80, y: 90, width: 420, height: 56)
        )

        XCTAssertFalse(presenter.canPresent(suggestion(), for: context))
    }

    func testCanPresentRejectsUnsupportedCoordinateSpaces() {
        let presenter = presenter()
        for coordinateSpace in [CaretGeometryCoordinateSpace.screenLocal, .unknown] {
            let context = textContext(
                caretRect: CGRect(x: 10_050, y: 110, width: 2, height: 18),
                focusedElementRect: CGRect(x: 10_020, y: 90, width: 420, height: 56),
                coordinateSpace: coordinateSpace
            )

            XCTAssertFalse(presenter.canPresent(suggestion(), for: context))
        }
    }

    private func presenter(
        screenContextProvider: (@MainActor (TextContext) -> OverlayPresenterGeometry.ScreenContext?)? = nil
    ) -> VisualInlineOverlayPresenter {
        VisualInlineOverlayPresenter(
            shortcutSettingsStore: KeyboardShortcutSettingsStore(),
            hintsProvider: OverlayShortcutHintsProvider(),
            screenContextProvider: screenContextProvider ?? { context in
                let primary = CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
                let secondary = CGRect(x: 10_000, y: 0, width: 900, height: 1_000)
                return OverlayPresenterGeometry.ScreenContext(
                    anchorRect: context.caretRect ?? secondary,
                    visibleFrame: secondary,
                    mainScreenFrame: primary,
                    screenFrames: [primary, secondary]
                )
            }
        )
    }

    private func suggestion() -> Suggestion {
        Suggestion(baseContextID: UUID(), visibleText: " completion", latencyMs: 12)
    }

    private func textContext(
        caretRect: CGRect,
        focusedElementRect: CGRect,
        coordinateSpace: CaretGeometryCoordinateSpace? = nil
    ) -> TextContext {
        TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: "Hello",
            selectedRange: NSRange(location: 5, length: 0),
            caretRect: caretRect,
            focusedElementRect: focusedElementRect,
            caretGeometryQuality: .directCaret,
            caretGeometryCoordinateSpace: coordinateSpace,
            observedCharacterWidth: 7
        )
    }
}
