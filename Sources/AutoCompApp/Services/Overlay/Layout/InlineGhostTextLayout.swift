import AppKit
import AutoCompCore

internal struct InlineGhostTextLayout: Equatable {
    struct Line: Equatable {
        let text: String
        let indent: CGFloat
        let width: CGFloat
    }

    enum PlacementReason: String, Equatable {
        case sameLine
        case wrappedLine
        case rightToLeft
        case clampedToVisibleFrame
    }

    let panelFrame: NSRect
    let lines: [Line]
    let lineHeight: CGFloat
    let keycapHintFrame: NSRect?
    let placementReason: PlacementReason

    static func resolve(
        text: String,
        font: NSFont,
        textDirection: TextDirection,
        anchorFrame: NSRect,
        inputFrame: NSRect?,
        visibleFrame: NSRect,
        observedCharacterWidth: CGFloat?,
        geometryQuality: CaretGeometryQuality,
        maxPanelWidth: CGFloat = 520
    ) -> InlineGhostTextLayout {
        let normalizedText = normalized(text)
        let lineHeight = max(16, ceil(font.ascender - font.descender + font.leading + 2))
        let keycapWidth = max(CGFloat(28), min(CGFloat(44), (observedCharacterWidth ?? font.pointSize * 0.55) * 5))
        let keycapGap: CGFloat = geometryQuality == .screenOCR ? 8 : 6
        let edgePadding: CGFloat = 4
        let minimumLineWidth = max(CGFloat(48), font.pointSize * 4)
        let sameLineAvailable: CGFloat
        switch textDirection {
        case .leftToRight:
            sameLineAvailable = visibleFrame.maxX - anchorFrame.minX
        case .rightToLeft:
            sameLineAvailable = anchorFrame.maxX - visibleFrame.minX
        }

        let shouldUseWrappedLine = textDirection == .leftToRight
            && sameLineAvailable < minimumLineWidth
        let rawPanelWidth = min(maxPanelWidth, max(minimumLineWidth, sameLineAvailable - edgePadding))
        let fallbackLineWidth = min(
            maxPanelWidth,
            max(
                minimumLineWidth,
                (inputFrame ?? visibleFrame).width - edgePadding * 2
            )
        )
        let panelWidth = shouldUseWrappedLine ? fallbackLineWidth : rawPanelWidth
        let wrappedLines = wrappedTextLines(
            normalizedText,
            font: font,
            maxLineWidth: panelWidth
        )
        let longestLineWidth = wrappedLines.map(\.width).max() ?? minimumLineWidth
        let measuredWidth = min(
            panelWidth,
            max(minimumLineWidth, longestLineWidth + keycapWidth + keycapGap)
        )
        let lines = linesWithIndent(
            wrappedLines,
            panelWidth: measuredWidth,
            direction: textDirection
        )
        let panelHeight = max(lineHeight, lineHeight * CGFloat(max(1, lines.count)))

        let desiredOrigin: CGPoint
        let reason: PlacementReason
        switch textDirection {
        case .leftToRight where shouldUseWrappedLine:
            let x = min(
                max((inputFrame?.minX ?? visibleFrame.minX) + edgePadding, visibleFrame.minX),
                visibleFrame.maxX - measuredWidth
            )
            desiredOrigin = CGPoint(x: x, y: anchorFrame.minY - panelHeight - 2)
            reason = .wrappedLine
        case .leftToRight:
            desiredOrigin = CGPoint(x: anchorFrame.minX, y: anchorFrame.minY)
            reason = lines.count > 1 ? .wrappedLine : .sameLine
        case .rightToLeft:
            desiredOrigin = CGPoint(x: anchorFrame.maxX - measuredWidth, y: anchorFrame.minY)
            reason = .rightToLeft
        }

        let clampedOrigin = CGPoint(
            x: min(max(desiredOrigin.x, visibleFrame.minX), max(visibleFrame.minX, visibleFrame.maxX - measuredWidth)),
            y: min(max(desiredOrigin.y, visibleFrame.minY), max(visibleFrame.minY, visibleFrame.maxY - panelHeight))
        )
        let placementReason: PlacementReason = clampedOrigin == desiredOrigin ? reason : .clampedToVisibleFrame
        let panelFrame = NSRect(
            x: clampedOrigin.x,
            y: clampedOrigin.y,
            width: measuredWidth,
            height: panelHeight
        )
        let keycapHintFrame = keycapFrame(
            lines: lines,
            panelFrame: panelFrame,
            lineHeight: lineHeight,
            keycapWidth: keycapWidth,
            keycapGap: keycapGap,
            direction: textDirection
        )

        return InlineGhostTextLayout(
            panelFrame: panelFrame,
            lines: lines,
            lineHeight: lineHeight,
            keycapHintFrame: keycapHintFrame,
            placementReason: placementReason
        )
    }

    private static func normalized(_ text: String) -> String {
        text
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func wrappedTextLines(
        _ text: String,
        font: NSFont,
        maxLineWidth: CGFloat
    ) -> [(text: String, width: CGFloat)] {
        guard !text.isEmpty else {
            return [("", 1)]
        }

        var lines: [(text: String, width: CGFloat)] = []
        var current = ""
        var currentWidth: CGFloat = 0
        for word in text.split(separator: " ").map(String.init) {
            let candidate = current.isEmpty ? word : current + " " + word
            let candidateWidth = measuredWidth(candidate, font: font)
            if !current.isEmpty, candidateWidth > maxLineWidth {
                lines.append((current, currentWidth))
                current = word
                currentWidth = min(measuredWidth(word, font: font), maxLineWidth)
            } else {
                current = candidate
                currentWidth = min(candidateWidth, maxLineWidth)
            }
        }

        if !current.isEmpty {
            lines.append((current, currentWidth))
        }
        return lines
    }

    private static func linesWithIndent(
        _ lines: [(text: String, width: CGFloat)],
        panelWidth: CGFloat,
        direction: TextDirection
    ) -> [Line] {
        lines.map { line in
            let indent: CGFloat
            switch direction {
            case .leftToRight:
                indent = 0
            case .rightToLeft:
                indent = max(0, panelWidth - line.width)
            }
            return Line(text: line.text, indent: indent, width: line.width)
        }
    }

    private static func measuredWidth(_ text: String, font: NSFont) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: font]).width + 2)
    }

    private static func keycapFrame(
        lines: [Line],
        panelFrame: NSRect,
        lineHeight: CGFloat,
        keycapWidth: CGFloat,
        keycapGap: CGFloat,
        direction: TextDirection
    ) -> NSRect? {
        guard let lastLine = lines.last else {
            return nil
        }

        let lineIndex = CGFloat(max(0, lines.count - 1))
        let height = max(CGFloat(12), lineHeight - 4)
        let y = panelFrame.minY + lineIndex * lineHeight + 2
        switch direction {
        case .leftToRight:
            let x = panelFrame.minX + lastLine.indent + lastLine.width + keycapGap
            guard x + keycapWidth <= panelFrame.maxX else {
                return nil
            }
            return NSRect(x: x, y: y, width: keycapWidth, height: height)
        case .rightToLeft:
            let x = panelFrame.minX + lastLine.indent - keycapGap - keycapWidth
            guard x >= panelFrame.minX else {
                return nil
            }
            return NSRect(x: x, y: y, width: keycapWidth, height: height)
        }
    }
}
