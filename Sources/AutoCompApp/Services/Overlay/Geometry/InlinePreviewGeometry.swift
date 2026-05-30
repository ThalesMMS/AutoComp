import AppKit

// TextContext and CaretGeometryQuality live in AutoCompApp; explicit import required after file split.
import AutoCompCore

struct InlinePreviewResolution {
    let layout: InlinePreviewLayout?
    let rejectionReason: String?

    init(layout: InlinePreviewLayout) {
        self.layout = layout
        self.rejectionReason = nil
    }

    init(rejectionReason: String) {
        self.layout = nil
        self.rejectionReason = rejectionReason
    }
}

enum InlinePreviewGeometry {
    private static let caretGap: CGFloat = 1
    private static let minimumUsefulWidth: CGFloat = 24
    private static let screenTolerance: CGFloat = 12

    static func layout(
        context: TextContext,
        contentSize: NSSize,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        screenFrames: [CGRect] = [],
        allowsLineWrapPlacement: Bool = false
    ) -> InlinePreviewLayout? {
        resolve(
            context: context,
            contentSize: contentSize,
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            screenFrames: screenFrames,
            allowsLineWrapPlacement: allowsLineWrapPlacement
        ).layout
    }

    static func resolve(
        context: TextContext,
        contentSize: NSSize,
        screenFrame: CGRect,
        visibleFrame: CGRect,
        screenFrames: [CGRect] = [],
        allowsLineWrapPlacement: Bool = false
    ) -> InlinePreviewResolution {
        guard isCollapsedSelection(context.selectedRange) else {
            return InlinePreviewResolution(rejectionReason: "selection-not-collapsed")
        }

        guard screenFrame.isFiniteAndNonEmpty, visibleFrame.isFiniteAndNonEmpty else {
            return InlinePreviewResolution(rejectionReason: "invalid-screen")
        }

        let validation = OverlayGeometryValidator(
            screenFrame: screenFrame,
            visibleFrame: visibleFrame,
            screenFrames: screenFrames
        ).validate(context: context)
        let focusedElementRect = validation.focusedElementRect
        let caretRect = validation.caretRect
        let previousGlyphRect = validation.previousGlyphRect
        let nextGlyphRect = validation.nextGlyphRect

        guard caretRect != nil || previousGlyphRect != nil || nextGlyphRect != nil else {
            return estimatedTextBoxLayout(
                context: context,
                focusedElementRect: focusedElementRect,
                contentSize: contentSize,
                visibleFrame: visibleFrame,
                fallbackReason: "missing-valid-text-metrics"
            )
        }

        if isWebLikeApp(context.app.bundleID),
           focusedElementRect != nil,
           previousGlyphRect == nil,
           !hasReliableFineCaret(caretRect) {
            return estimatedTextBoxLayout(
                context: context,
                focusedElementRect: focusedElementRect,
                contentSize: contentSize,
                visibleFrame: visibleFrame,
                fallbackReason: "web-missing-glyph-reference"
            )
        }

        let textDirection = TextDirectionDetector.direction(for: context.textBeforeCursor)
        guard let insertionX = insertionPointX(
            caretRect: caretRect,
            previousGlyphRect: previousGlyphRect,
            textDirection: textDirection
        ) else {
            return estimatedTextBoxLayout(
                context: context,
                focusedElementRect: focusedElementRect,
                contentSize: contentSize,
                visibleFrame: visibleFrame,
                fallbackReason: "missing-insertion-x"
            )
        }

        let x: CGFloat
        let availableWidth: CGFloat
        switch textDirection {
        case .leftToRight:
            x = insertionX + caretGap
            guard x >= visibleFrame.minX - screenTolerance,
                  x <= visibleFrame.maxX + screenTolerance else {
                return InlinePreviewResolution(rejectionReason: "insertion-outside-visible-frame")
            }
            let rightSideWidth = visibleFrame.maxX - x
            guard rightSideWidth >= minimumUsefulWidth || allowsLineWrapPlacement else {
                return InlinePreviewResolution(rejectionReason: "insufficient-right-side-space")
            }
            availableWidth = max(rightSideWidth, minimumUsefulWidth)
        case .rightToLeft:
            let rightEdge = insertionX - caretGap
            guard rightEdge >= visibleFrame.minX - screenTolerance,
                  rightEdge <= visibleFrame.maxX + screenTolerance else {
                return InlinePreviewResolution(rejectionReason: "insertion-outside-visible-frame")
            }
            let leftSideWidth = rightEdge - visibleFrame.minX
            guard leftSideWidth >= minimumUsefulWidth || allowsLineWrapPlacement else {
                return InlinePreviewResolution(rejectionReason: "insufficient-left-side-space")
            }
            availableWidth = max(leftSideWidth, minimumUsefulWidth)
            let width = min(max(contentSize.width, minimumUsefulWidth), availableWidth)
            x = rightEdge - width
        }

        guard x >= visibleFrame.minX - screenTolerance,
              x <= visibleFrame.maxX + screenTolerance else {
            return InlinePreviewResolution(rejectionReason: "insertion-outside-visible-frame")
        }

        guard let referenceRect = lineReferenceRect(
            caretRect: caretRect,
            previousGlyphRect: previousGlyphRect,
            nextGlyphRect: nextGlyphRect
        ) else {
            return InlinePreviewResolution(rejectionReason: "missing-line-reference")
        }

        let height = max(1, max(contentSize.height, referenceRect.height))
        let y = referenceRect.maxY - height
        let size = NSSize(width: min(max(contentSize.width, minimumUsefulWidth), availableWidth), height: height)
        let frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
        guard visibleFrame.insetBy(dx: -screenTolerance, dy: -screenTolerance).contains(CGPoint(x: frame.midX, y: frame.midY)) else {
            return InlinePreviewResolution(rejectionReason: "panel-outside-visible-frame")
        }

        return InlinePreviewLayout(
            origin: CGPoint(x: x, y: y),
            size: size,
            source: .exactAX,
            inputFrame: focusedElementRect
        )
        .resolution
    }

    static func referenceHeight(for context: TextContext) -> CGFloat {
        [
            context.previousGlyphRect,
            context.lineReferenceRect,
            context.nextGlyphRect,
            context.caretRect
        ]
        .compactMap { $0?.height }
        .first { $0.isFinite && $0 > 0 }
        ?? 14
    }

    static func fontSize(for context: TextContext) -> CGFloat {
        max(12, min(18, referenceHeight(for: context)))
    }

    private static func isCollapsedSelection(_ selectedRange: NSRange?) -> Bool {
        selectedRange?.length == 0
    }

    private static func insertionPointX(
        caretRect: CGRect?,
        previousGlyphRect: CGRect?,
        textDirection: TextDirection
    ) -> CGFloat? {
        if textDirection == .rightToLeft {
            if let caretRect, OverlayGeometry.isFineCaret(caretRect) {
                return caretRect.minX
            }

            if let previousGlyphRect {
                return previousGlyphRect.minX
            }

            if let caretRect {
                return caretRect.minX
            }

            return nil
        }

        if let caretRect, OverlayGeometry.isFineCaret(caretRect) {
            return caretRect.maxX
        }

        if let previousGlyphRect {
            return previousGlyphRect.maxX
        }

        if let caretRect {
            return caretRect.minX
        }

        return nil
    }

    private static func hasReliableFineCaret(_ caretRect: CGRect?) -> Bool {
        guard let caretRect else {
            return false
        }
        return OverlayGeometry.isFineCaret(caretRect)
    }

    private static func lineReferenceRect(
        caretRect: CGRect?,
        previousGlyphRect: CGRect?,
        nextGlyphRect: CGRect?
    ) -> CGRect? {
        if let previousGlyphRect {
            return previousGlyphRect
        }
        if let nextGlyphRect {
            return nextGlyphRect
        }
        return caretRect
    }

    private static func estimatedTextBoxLayout(
        context: TextContext,
        focusedElementRect: CGRect?,
        contentSize: NSSize,
        visibleFrame: CGRect,
        fallbackReason: String
    ) -> InlinePreviewResolution {
        guard let focusedElementRect else {
            return InlinePreviewResolution(rejectionReason: fallbackReason)
        }

        let horizontalPadding = estimatedHorizontalPadding(for: context)
        let visibleFocus = focusedElementRect.intersection(visibleFrame)
        let textDirection = TextDirectionDetector.direction(for: context.textBeforeCursor)
        guard visibleFocus.isFiniteAndNonEmpty,
              visibleFocus.width >= minimumUsefulWidth + horizontalPadding * 2,
              visibleFocus.height >= 12 else {
            return InlinePreviewResolution(rejectionReason: "invalid-focused-element-fallback")
        }

        let fontSize = estimatedFontSize(for: focusedElementRect, context: context)
        let font = NSFont.systemFont(ofSize: fontSize)
        let lineHeight = estimatedLineHeight(for: font)

        let leftLimit = visibleFocus.minX + horizontalPadding
        let rightLimit = visibleFocus.maxX - 2
        let maxXWithUsefulSpace = rightLimit - minimumUsefulWidth
        guard maxXWithUsefulSpace >= leftLimit else {
            return InlinePreviewResolution(rejectionReason: "insufficient-focused-element-space")
        }

        let maxTextLineWidth = max(1, rightLimit - leftLimit - caretGap)
        let lineEstimate = estimatedVisibleLine(
            in: context.textBeforeCursor,
            font: font,
            maxLineWidth: maxTextLineWidth
        )
        let measuredLineWidth = lineEstimate.width
        let x: CGFloat
        let availableWidth: CGFloat
        let estimatedAnchorX: CGFloat
        switch textDirection {
        case .leftToRight:
            estimatedAnchorX = leftLimit + measuredLineWidth + caretGap
            x = min(max(estimatedAnchorX, leftLimit), maxXWithUsefulSpace)
            availableWidth = rightLimit - x
            guard availableWidth >= minimumUsefulWidth else {
                return InlinePreviewResolution(rejectionReason: "insufficient-right-side-space")
            }
        case .rightToLeft:
            estimatedAnchorX = rightLimit - measuredLineWidth - caretGap
            let minimumRightEdge = leftLimit + minimumUsefulWidth
            let rightEdge = min(max(estimatedAnchorX, minimumRightEdge), rightLimit)
            availableWidth = rightEdge - leftLimit
            guard availableWidth >= minimumUsefulWidth else {
                return InlinePreviewResolution(rejectionReason: "insufficient-left-side-space")
            }
            let width = min(max(contentSize.width, minimumUsefulWidth), availableWidth)
            x = rightEdge - width
        }

        let height = max(1, max(contentSize.height, lineHeight))
        let verticalPadding = estimatedVerticalPadding(for: visibleFocus, context: context)
        let visibleLineCapacity = max(1, Int(floor((visibleFocus.height - verticalPadding * 2) / lineHeight)))
        let desiredLineIndex = min(lineEstimate.lineIndex, max(0, visibleLineCapacity - 1))
        let topY = visibleFocus.maxY - verticalPadding - (CGFloat(desiredLineIndex) * lineHeight)
        let minY = visibleFocus.minY + 2
        let maxY = visibleFocus.maxY - height - 2
        guard maxY >= minY else {
            return InlinePreviewResolution(rejectionReason: "insufficient-focused-element-height")
        }
        let y = min(
            max(topY - height, minY),
            maxY
        )

        let size = NSSize(width: min(max(contentSize.width, minimumUsefulWidth), availableWidth), height: height)
        let frame = CGRect(origin: CGPoint(x: x, y: y), size: size)
        guard visibleFocus.insetBy(dx: -screenTolerance, dy: -screenTolerance).contains(CGPoint(x: frame.midX, y: frame.midY)) else {
            return InlinePreviewResolution(rejectionReason: "estimated-panel-outside-focused-element")
        }

        GeometryDebug.log("metric=text-box-estimate reason=\(fallbackReason) focused=\(focusedElementRect) lineIndex=\(lineEstimate.lineIndex) lineWidth=\(measuredLineWidth) estimatedAnchorX=\(estimatedAnchorX) direction=\(textDirection) panel=\(frame)")
        return InlinePreviewLayout(
            origin: CGPoint(x: x, y: y),
            size: size,
            source: .textBoxEstimate,
            inputFrame: focusedElementRect
        ).resolution
    }

    private static func estimatedFontSize(for focusedElementRect: CGRect, context: TextContext) -> CGFloat {
        if isWebLikeApp(context.app.bundleID) {
            return 14
        }
        return min(17, max(13, focusedElementRect.height * 0.42))
    }

    private static func estimatedHorizontalPadding(for context: TextContext) -> CGFloat {
        isWebLikeApp(context.app.bundleID) ? 4 : 8
    }

    private static func estimatedLineHeight(for font: NSFont) -> CGFloat {
        max(16, ceil(font.ascender - font.descender + font.leading + 2))
    }

    private static func estimatedVerticalPadding(for visibleFocus: CGRect, context: TextContext) -> CGFloat {
        if isWebLikeApp(context.app.bundleID) {
            return min(8, max(5, visibleFocus.height * 0.12))
        }
        return max(CGFloat(4), min(CGFloat(10), visibleFocus.height * 0.16))
    }

    private static func isWebLikeApp(_ bundleID: String) -> Bool {
        [
            "com.openai.codex",
            "com.google.Chrome",
            "com.brave.Browser",
            "com.microsoft.edgemac",
            "company.thebrowser.Browser",
            "company.thebrowser.dia",
            "com.todesktop.230313mzl4w4u92"
        ].contains(bundleID)
    }

    private static func estimatedVisibleLine(in text: String, font: NSFont, maxLineWidth: CGFloat) -> (width: CGFloat, lineIndex: Int) {
        let lineText = lastLine(in: text)
        var currentLine = ""
        var currentWidth: CGFloat = 0
        var visualLineCount = 1
        let attributes: [NSAttributedString.Key: Any] = [.font: font]

        for character in lineText {
            let candidate = currentLine + String(character)
            let candidateWidth = ceil((candidate as NSString).size(withAttributes: attributes).width)
            if !currentLine.isEmpty, candidateWidth > maxLineWidth {
                visualLineCount += 1
                currentLine = String(character)
                currentWidth = ceil((currentLine as NSString).size(withAttributes: attributes).width)
            } else {
                currentLine = candidate
                currentWidth = candidateWidth
            }
        }

        return (width: min(currentWidth, maxLineWidth), lineIndex: visualLineCount - 1)
    }

    private static func lastLine(in text: String) -> String {
        if let lastNewline = text.lastIndex(where: { $0 == "\n" || $0 == "\r" }) {
            return String(text[text.index(after: lastNewline)...])
        }
        return text
    }
}

extension InlinePreviewLayout {
    var resolution: InlinePreviewResolution {
        InlinePreviewResolution(layout: self)
    }
}
