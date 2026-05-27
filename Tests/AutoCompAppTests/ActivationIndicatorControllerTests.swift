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
            mode: .fieldEdge,
            displayMode: .disabled,
            context: context()
        ))
        XCTAssertNil(ActivationIndicatorController.placement(
            mode: .debugGeometryQuality,
            displayMode: .disabled,
            context: context()
        ))
    }

    func testDefaultModeIsQuietFieldEdgeUnlessGeometryDebugIsEnabled() {
        XCTAssertEqual(ActivationIndicatorController.defaultMode(isGeometryDebugEnabled: false), .fieldEdge)
        XCTAssertEqual(ActivationIndicatorController.defaultMode(isGeometryDebugEnabled: true), .debugGeometryQuality)
    }

    func testModesExposeNormalAndDebugOptions() {
        XCTAssertEqual(
            Set(ActivationIndicatorMode.allCases),
            [.hidden, .fieldEdge, .caretAnchor, .debugGeometryQuality]
        )
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

    func testDebugGeometryQualityPlacementUsesCaretAnchorAndCarriesQuality() {
        let placement = ActivationIndicatorController.placement(
            mode: .debugGeometryQuality,
            displayMode: .inline,
            context: context(
                caretRect: CGRect(x: 100, y: 200, width: 2, height: 20),
                caretGeometryQuality: .glyph
            )
        )

        XCTAssertEqual(
            placement,
            ActivationIndicatorPlacement(
                frame: CGRect(x: 106, y: 201, width: 76, height: 18),
                mode: .debugGeometryQuality,
                geometryQuality: .glyph
            )
        )
    }

    func testDebugGeometryQualityFallsBackToFieldEdgeWhenCaretAnchorIsUnavailable() {
        let placement = ActivationIndicatorController.placement(
            mode: .debugGeometryQuality,
            displayMode: .inline,
            context: context(
                caretRect: nil,
                focusedElementRect: CGRect(x: 80, y: 180, width: 260, height: 44),
                caretGeometryQuality: .unavailable
            )
        )

        XCTAssertEqual(
            placement,
            ActivationIndicatorPlacement(
                frame: CGRect(x: 258, y: 186, width: 76, height: 18),
                mode: .debugGeometryQuality,
                geometryQuality: .unavailable
            )
        )
    }

    func testDebugGeometryQualityLabelsCoverEveryQuality() {
        XCTAssertEqual(ActivationIndicatorController.debugLabel(for: .directCaret), "direct")
        XCTAssertEqual(ActivationIndicatorController.debugLabel(for: .glyph), "glyph")
        XCTAssertEqual(ActivationIndicatorController.debugLabel(for: .lineMetric), "line")
        XCTAssertEqual(ActivationIndicatorController.debugLabel(for: .elementFrame), "element")
        XCTAssertEqual(ActivationIndicatorController.debugLabel(for: .screenOCR), "OCR")
        XCTAssertEqual(ActivationIndicatorController.debugLabel(for: .unavailable), "unavailable")
    }

    func testNormalFieldEdgePlacementDoesNotExposeDebugSizing() {
        let direct = ActivationIndicatorController.placement(
            mode: .fieldEdge,
            displayMode: .inline,
            context: context(
                focusedElementRect: CGRect(x: 80, y: 180, width: 260, height: 44),
                caretGeometryQuality: .directCaret
            )
        )
        let ocr = ActivationIndicatorController.placement(
            mode: .fieldEdge,
            displayMode: .inline,
            context: context(
                focusedElementRect: CGRect(x: 80, y: 180, width: 260, height: 44),
                caretGeometryQuality: .screenOCR
            )
        )

        XCTAssertEqual(direct?.frame, CGRect(x: 326, y: 186, width: 8, height: 8))
        XCTAssertEqual(ocr?.frame, CGRect(x: 326, y: 186, width: 8, height: 8))
        XCTAssertEqual(direct?.mode, .fieldEdge)
        XCTAssertEqual(ocr?.mode, .fieldEdge)
    }

    func testPlacementCarriesStableFieldIdentity() throws {
        let stableFieldIdentity = StableFieldIdentity(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            role: "AXTextArea",
            focusedElementFrame: CGRect(x: 80, y: 180, width: 260, height: 44),
            focusChangeSequence: 5
        )

        let placement = try XCTUnwrap(ActivationIndicatorController.placement(
            mode: .fieldEdge,
            displayMode: .inline,
            context: context(
                focusedElementRect: CGRect(x: 80, y: 180, width: 260, height: 44),
                stableFieldIdentity: stableFieldIdentity
            )
        ))

        XCTAssertEqual(placement.stableFieldIdentity, stableFieldIdentity)
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
        selectedRange: NSRange? = NSRange(location: 5, length: 0),
        caretGeometryQuality: CaretGeometryQuality = .unavailable,
        stableFieldIdentity: StableFieldIdentity? = nil
    ) -> TextContext {
        TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: "field",
            stableFieldIdentity: stableFieldIdentity,
            textBeforeCursor: "Hello",
            selectedRange: selectedRange,
            caretRect: caretRect,
            focusedElementRect: focusedElementRect,
            caretGeometryQuality: caretGeometryQuality
        )
    }
}
