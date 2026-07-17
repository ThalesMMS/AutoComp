import AppKit
import AutoCompCore

internal struct SimpleCaretPopupLayout: Equatable {
    enum PlacementReason: String, Equatable {
        case caret
        case focusedElement
        case clampedToVisibleFrame
    }

    let panelFrame: NSRect
    let anchorFrame: NSRect
    let placementReason: PlacementReason

    static func resolve(
        text: String,
        context: TextContext,
        font: NSFont,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        screenFrames: [CGRect] = [],
        maxPanelWidth: CGFloat = 360
    ) -> SimpleCaretPopupLayout? {
        guard context.selectedRange?.length == 0 else {
            return nil
        }

        let normalizedText = normalized(text)
        guard !normalizedText.isEmpty,
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

        let measured = measuredSize(for: normalizedText, font: font)
        let panelWidth = min(maxPanelWidth, max(CGFloat(92), measured.width + 60))
        let panelHeight = max(CGFloat(28), measured.height + 12)
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
        let clampResult = visibleFrame.clampingOrigin(
            desiredOrigin,
            panelSize: CGSize(width: panelWidth, height: panelHeight)
        )
        let placementReason = clampResult.wasClamped ? PlacementReason.clampedToVisibleFrame : reason

        return SimpleCaretPopupLayout(
            panelFrame: NSRect(
                x: clampResult.origin.x,
                y: clampResult.origin.y,
                width: panelWidth,
                height: panelHeight
            ),
            anchorFrame: anchor,
            placementReason: placementReason
        )
    }

    static func normalized(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func measuredSize(for text: String, font: NSFont) -> NSSize {
        let size = (text as NSString).size(withAttributes: [.font: font])
        return NSSize(width: ceil(size.width), height: ceil(size.height))
    }
}
