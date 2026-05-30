import AppKit
import AutoCompCore

internal struct MultiSuggestionPopupLayout: Equatable {
    enum PlacementReason: String, Equatable {
        case caret
        case focusedElement
        case clampedToVisibleFrame
    }

    let panelFrame: NSRect
    let anchorFrame: NSRect
    let placementReason: PlacementReason

    static func resolve(
        suggestion: Suggestion,
        context: TextContext,
        font: NSFont,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        screenFrames: [CGRect] = [],
        maxPanelWidth: CGFloat = 420
    ) -> MultiSuggestionPopupLayout? {
        guard suggestion.hasMultipleAlternatives,
              context.selectedRange?.length == 0,
              screenFrame.isFiniteAndNonEmpty,
              visibleFrame.isFiniteAndNonEmpty else {
            return nil
        }

        let validation = OverlayGeometryValidator(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            screenFrames: screenFrames
        ).validate(context: context)

        let anchor: NSRect
        let reason: PlacementReason
        if let caretRect = validation.caretRect
            ?? validation.previousGlyphRect
            ?? validation.nextGlyphRect {
            anchor = caretRect
            reason = .caret
        } else if let focusedElementRect = validation.focusedElementRect {
            anchor = focusedElementRect
            reason = .focusedElement
        } else {
            return nil
        }

        let longest = suggestion.alternatives
            .map { SimpleCaretPopupLayout.normalized($0.visibleText) }
            .max { lhs, rhs in measuredWidth(lhs, font: font) < measuredWidth(rhs, font: font) } ?? ""
        guard !longest.isEmpty else {
            return nil
        }

        let panelWidth = min(maxPanelWidth, max(CGFloat(220), measuredWidth(longest, font: font) + 62))
        let rowCount = min(3, max(1, suggestion.alternatives.count))
        let panelHeight = CGFloat(rowCount * 30 + 12)
        let textDirection = TextDirectionDetector.direction(for: context.textBeforeCursor)
        let desiredX: CGFloat
        switch textDirection {
        case .leftToRight:
            desiredX = anchor.minX
        case .rightToLeft:
            desiredX = anchor.maxX - panelWidth
        }

        let belowY = anchor.minY - panelHeight - 6
        let desiredY = belowY >= visibleFrame.minY
            ? belowY
            : anchor.maxY + 6
        let desiredOrigin = CGPoint(x: desiredX, y: desiredY)
        let clampedOrigin = CGPoint(
            x: min(max(desiredOrigin.x, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - panelWidth)),
            y: min(max(desiredOrigin.y, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - panelHeight))
        )
        let placementReason = clampedOrigin == desiredOrigin ? reason : .clampedToVisibleFrame

        return MultiSuggestionPopupLayout(
            panelFrame: NSRect(x: clampedOrigin.x, y: clampedOrigin.y, width: panelWidth, height: panelHeight),
            anchorFrame: anchor,
            placementReason: placementReason
        )
    }

    private static func measuredWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width)
    }
}
