import ApplicationServices
import AppKit
import AutoCompCore
import Foundation

struct AXTextGeometrySnapshot {
    var focusedElementRect: CGRect?
    var caretRect: CGRect?
    var previousGlyphRect: CGRect?
    var nextGlyphRect: CGRect?
    var lineReferenceRect: CGRect?
    var caretGeometryQuality: CaretGeometryQuality
    var observedCharacterWidth: CGFloat?
}

struct AXTextGeometryResolver {
    private let axHelper: AXHelper
    private let textMarkerFallback: AXTextMarkerGeometryFallback

    init(
        axHelper: AXHelper = AXHelper(),
        textMarkerFallback: AXTextMarkerGeometryFallback = AXTextMarkerGeometryFallback()
    ) {
        self.axHelper = axHelper
        self.textMarkerFallback = textMarkerFallback
    }

    func resolve(snapshot: AXFocusSnapshot) -> AXTextGeometrySnapshot {
        let focusedElement = snapshot.focusedElement
        var geometry = AXTextGeometrySnapshot(
            focusedElementRect: axHelper.elementRect(for: focusedElement),
            caretRect: axHelper.caretRect(for: focusedElement, selectedRange: snapshot.selectedRange),
            previousGlyphRect: axHelper.previousGlyphRect(for: focusedElement, selectedRange: snapshot.selectedRange),
            nextGlyphRect: axHelper.nextGlyphRect(
                for: focusedElement,
                selectedRange: snapshot.selectedRange,
                textLength: snapshot.textLength
            ),
            lineReferenceRect: nil,
            caretGeometryQuality: .unavailable,
            observedCharacterWidth: nil
        )
        geometry.lineReferenceRect = geometry.previousGlyphRect
        geometry.caretGeometryQuality = Self.bestQuality(
            caretRect: geometry.caretRect,
            previousGlyphRect: geometry.previousGlyphRect,
            lineReferenceRect: geometry.lineReferenceRect,
            focusedElementRect: geometry.focusedElementRect
        )
        geometry.observedCharacterWidth = Self.observedCharacterWidth(
            previousGlyphRect: geometry.previousGlyphRect,
            nextGlyphRect: geometry.nextGlyphRect
        )

        if AXTextMarkerGeometryFallback.isEligibleBrowser(bundleID: snapshot.bundleID),
           let textMarkerCaretRect = textMarkerFallback.resolve(
            snapshot: snapshot,
            geometry: geometry
           ) {
            geometry.caretRect = textMarkerCaretRect
            geometry.previousGlyphRect = nil
            geometry.nextGlyphRect = nil
            geometry.lineReferenceRect = textMarkerCaretRect
            geometry.caretGeometryQuality = .directCaret
            geometry.observedCharacterWidth = nil
        } else if let codexCaretRect = codexProseMirrorLineCaretRect(
            snapshot: snapshot,
            geometry: geometry
        ) {
            geometry.caretRect = codexCaretRect
            geometry.previousGlyphRect = nil
            geometry.nextGlyphRect = nil
            geometry.lineReferenceRect = codexCaretRect
            geometry.caretGeometryQuality = .lineMetric
            geometry.observedCharacterWidth = nil
            GeometryDebug.log("ax-fallback source=codex-prosemirror-line caretRect=\(codexCaretRect) focusedElementRect=\(String(describing: geometry.focusedElementRect))")
        } else if let googleDocsCaretRect = googleDocsAXLineCaretRect(
            snapshot: snapshot,
            geometry: geometry
        ) {
            geometry.caretRect = googleDocsCaretRect
            geometry.previousGlyphRect = nil
            geometry.nextGlyphRect = nil
            geometry.lineReferenceRect = googleDocsCaretRect
            geometry.caretGeometryQuality = .lineMetric
            geometry.observedCharacterWidth = nil
            GeometryDebug.log("ax-fallback source=google-docs-braille-line caretRect=\(googleDocsCaretRect) focusedElementRect=\(String(describing: geometry.focusedElementRect))")
        }

        return geometry
    }

    static func bestQuality(
        caretRect: CGRect?,
        previousGlyphRect: CGRect?,
        lineReferenceRect: CGRect?,
        focusedElementRect: CGRect?
    ) -> CaretGeometryQuality {
        if caretRect != nil {
            return .directCaret
        }

        if previousGlyphRect != nil {
            return .glyph
        }

        if lineReferenceRect != nil {
            return .lineMetric
        }

        if focusedElementRect != nil {
            return .elementFrame
        }

        return .unavailable
    }

    static func observedCharacterWidth(
        previousGlyphRect: CGRect?,
        nextGlyphRect: CGRect?
    ) -> CGFloat? {
        for rect in [previousGlyphRect, nextGlyphRect].compactMap({ $0 }) {
            guard rect.width.isFinite,
                  rect.width >= 1,
                  rect.width <= 80 else {
                continue
            }
            return rect.width
        }
        return nil
    }

    func shouldUseScreenOCRFallback(
        snapshot: AXFocusSnapshot,
        geometry: AXTextGeometrySnapshot
    ) -> Bool {
        guard snapshot.bundleID == "com.google.Chrome",
              snapshot.domain?.contains("docs.google.com") == true else {
            return false
        }
        guard snapshot.isGoogleDocsElement else {
            return false
        }
        guard let text = snapshot.textBeforeCursor,
              !isWeakText(text) else {
            GeometryDebug.log("ax-fallback skipped reason=google-docs-braille-setup-missing-or-weak-text")
            return false
        }

        return hasWeakTextGeometry(
            focusedElementRect: geometry.focusedElementRect,
            caretRect: geometry.caretRect,
            previousGlyphRect: geometry.previousGlyphRect
        )
    }

    private func codexProseMirrorLineCaretRect(
        snapshot: AXFocusSnapshot,
        geometry: AXTextGeometrySnapshot
    ) -> CGRect? {
        guard snapshot.bundleID == "com.openai.codex",
              snapshot.isCodexComposerElement,
              let selectedRange = snapshot.selectedRange,
              selectedRange.length == 0,
              let text = snapshot.textBeforeCursor,
              !isWeakText(text),
              hasWeakTextGeometry(
                focusedElementRect: geometry.focusedElementRect,
                caretRect: geometry.caretRect,
                previousGlyphRect: geometry.previousGlyphRect
              ),
              let focusedElementRect = geometry.focusedElementRect,
              isFiniteAndNonEmpty(focusedElementRect),
              focusedElementRect.width >= 80,
              focusedElementRect.height >= 18 else {
            return nil
        }

        let horizontalPadding: CGFloat = 4
        let verticalPadding = min(CGFloat(8), max(CGFloat(6), focusedElementRect.height * 0.16))
        let font = NSFont.systemFont(ofSize: 14)
        let lineHeight: CGFloat = 20
        let caretHeight: CGFloat = 18
        let maxLineWidth = max(1, focusedElementRect.width - horizontalPadding * 2 - 2)
        let lineEstimate = estimatedVisibleLine(
            in: text,
            font: font,
            maxLineWidth: maxLineWidth
        )

        let visibleLineCapacity = max(1, Int(floor((focusedElementRect.height - verticalPadding * 2) / lineHeight)))
        let lineIndex = min(lineEstimate.lineIndex, max(0, visibleLineCapacity - 1))
        let x = min(
            max(focusedElementRect.minX + horizontalPadding + lineEstimate.width, focusedElementRect.minX + horizontalPadding),
            focusedElementRect.maxX - 24
        )
        let topY = focusedElementRect.minY + verticalPadding + CGFloat(lineIndex) * lineHeight
        let y = min(
            max(topY, focusedElementRect.minY + 2),
            focusedElementRect.maxY - caretHeight - 2
        )

        guard x.isFinite,
              y.isFinite,
              x > focusedElementRect.minX,
              y >= focusedElementRect.minY,
              y + caretHeight <= focusedElementRect.maxY else {
            return nil
        }

        return CGRect(x: x, y: y, width: 1, height: caretHeight)
    }

    private func googleDocsAXLineCaretRect(
        snapshot: AXFocusSnapshot,
        geometry: AXTextGeometrySnapshot
    ) -> CGRect? {
        guard snapshot.bundleID == "com.google.Chrome",
              snapshot.domain?.contains("docs.google.com") == true,
              snapshot.isGoogleDocsElement,
              let text = snapshot.textBeforeCursor,
              !isWeakText(text),
              hasWeakTextGeometry(
                focusedElementRect: geometry.focusedElementRect,
                caretRect: geometry.caretRect,
                previousGlyphRect: geometry.previousGlyphRect
              ),
              let focusedElementRect = geometry.focusedElementRect,
              isGoogleDocsAXLineMetric(focusedElementRect) else {
            return nil
        }

        return CGRect(
            x: focusedElementRect.minX,
            y: focusedElementRect.minY,
            width: 1,
            height: 16
        )
    }

    private func hasWeakTextGeometry(
        focusedElementRect: CGRect?,
        caretRect: CGRect?,
        previousGlyphRect: CGRect?
    ) -> Bool {
        if let focusedElementRect, focusedElementRect.height < 12 {
            return true
        }

        let usableCaret = caretRect.map(isUsableGoogleDocsMetricRect) ?? false
        let usablePreviousGlyph = previousGlyphRect.map(isUsableGoogleDocsMetricRect) ?? false
        return !usableCaret && !usablePreviousGlyph
    }

    private func isUsableGoogleDocsMetricRect(_ rect: CGRect) -> Bool {
        rect.width.isFinite
            && rect.height.isFinite
            && rect.height >= 8
            && rect.height <= 80
            && !(abs(rect.minX) < 0.5 && abs(rect.minY) < 0.5)
    }

    private func isGoogleDocsAXLineMetric(_ rect: CGRect) -> Bool {
        rect.minX.isFinite
            && rect.minY.isFinite
            && rect.width.isFinite
            && rect.height.isFinite
            && rect.minX > 1
            && rect.minY > 1
            && rect.width >= 80
            && rect.height > 0
            && rect.height <= 4
    }

    private func isFiniteAndNonEmpty(_ rect: CGRect) -> Bool {
        rect.minX.isFinite
            && rect.minY.isFinite
            && rect.width.isFinite
            && rect.height.isFinite
            && rect.width > 0
            && rect.height > 0
    }

    private func isWeakText(_ text: String) -> Bool {
        let scalars = text.unicodeScalars.filter { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar)
        }
        guard !scalars.isEmpty else {
            return true
        }
        return scalars.allSatisfy { scalar in
            scalar.value == 0x200B
                || scalar.value == 0x200C
                || scalar.value == 0x200D
                || scalar.value == 0xFEFF
                || scalar.value == 0xFFFC
        }
    }

    private func estimatedVisibleLine(in text: String, font: NSFont, maxLineWidth: CGFloat) -> (width: CGFloat, lineIndex: Int) {
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

    private func lastLine(in text: String) -> String {
        if let lastNewline = text.lastIndex(where: { $0 == "\n" || $0 == "\r" }) {
            return String(text[text.index(after: lastNewline)...])
        }
        return text
    }
}
