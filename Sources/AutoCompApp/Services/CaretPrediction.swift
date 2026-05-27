import AutoCompCore
import CoreGraphics
import Foundation

enum CaretPrediction {
    private static let minimumObservedCharacterWidth: CGFloat = 1
    private static let maximumObservedCharacterWidth: CGFloat = 80
    private static let maximumPredictedOffset: CGFloat = 480

    static func predictedCaretRect(
        acceptedChunk: String,
        oldCaretRect: CGRect,
        geometryQuality: CaretGeometryQuality,
        observedCharacterWidth: CGFloat?
    ) -> CGRect? {
        guard geometryQuality.supportsPostAcceptancePrediction,
              !acceptedChunk.isEmpty,
              acceptedChunk.rangeOfCharacter(from: .newlines) == nil,
              oldCaretRect.isFiniteAndNonEmptyForPrediction,
              let observedCharacterWidth,
              observedCharacterWidth.isFinite,
              observedCharacterWidth >= minimumObservedCharacterWidth,
              observedCharacterWidth <= maximumObservedCharacterWidth else {
            return nil
        }

        let offset = CGFloat(acceptedChunk.count) * observedCharacterWidth
        guard offset > 0,
              offset <= maximumPredictedOffset else {
            return nil
        }

        return oldCaretRect.offsetBy(dx: offset, dy: 0)
    }

    static func predictedContext(
        afterAccepting acceptedChunk: String,
        from context: TextContext,
        geometryQuality: CaretGeometryQuality? = nil,
        observedCharacterWidth: CGFloat? = nil
    ) -> TextContext? {
        guard let oldCaretRect = context.caretRect,
              let predictedCaretRect = predictedCaretRect(
                acceptedChunk: acceptedChunk,
                oldCaretRect: oldCaretRect,
                geometryQuality: geometryQuality ?? usableGeometryQuality(for: context),
                observedCharacterWidth: observedCharacterWidth
                    ?? context.observedCharacterWidth
                    ?? inferredObservedCharacterWidth(for: context)
              ) else {
            return nil
        }

        return TextContext(
            id: context.id,
            app: context.app,
            domain: context.domain,
            focusedElementID: context.focusedElementID,
            stableFieldIdentity: context.stableFieldIdentity,
            textBeforeCursor: context.textBeforeCursor + acceptedChunk,
            textAfterCursor: context.textAfterCursor,
            selectedText: context.selectedText,
            fullTextWindow: context.fullTextWindow,
            selectedRange: context.selectedRange,
            caretRect: predictedCaretRect,
            focusedElementRect: context.focusedElementRect,
            previousGlyphRect: context.previousGlyphRect,
            nextGlyphRect: context.nextGlyphRect,
            lineReferenceRect: context.lineReferenceRect,
            caretGeometryQuality: context.caretGeometryQuality,
            observedCharacterWidth: context.observedCharacterWidth,
            languageHint: context.languageHint,
            captureSources: context.captureSources,
            createdAt: context.createdAt
        )
    }

    static func usableGeometryQuality(for context: TextContext) -> CaretGeometryQuality {
        if context.caretGeometryQuality != .unavailable {
            return context.caretGeometryQuality
        }
        return inferredGeometryQuality(for: context)
    }

    static func inferredGeometryQuality(for context: TextContext) -> CaretGeometryQuality {
        if context.captureSources.contains(.screenOCR) {
            return .screenOCR
        }

        if let caretRect = context.caretRect,
           OverlayGeometry.isFineCaret(caretRect) {
            return .directCaret
        }

        if context.previousGlyphRect != nil {
            return .glyph
        }

        if context.lineReferenceRect != nil {
            return .lineMetric
        }

        if context.focusedElementRect != nil {
            return .elementFrame
        }

        return .unavailable
    }

    static func inferredObservedCharacterWidth(for context: TextContext) -> CGFloat? {
        guard let width = context.previousGlyphRect?.width,
              width.isFinite,
              width >= minimumObservedCharacterWidth,
              width <= maximumObservedCharacterWidth else {
            return nil
        }
        return width
    }
}

private extension CGRect {
    var isFiniteAndNonEmptyForPrediction: Bool {
        origin.x.isFinite
            && origin.y.isFinite
            && size.width.isFinite
            && size.height.isFinite
            && width > 0
            && height > 0
    }
}
