import AppKit
import CoreText
import Foundation

struct VisibleTextLineEstimate: Equatable {
    let width: CGFloat
    let lineIndex: Int
}

enum VisibleTextLineEstimator {
    static func estimate(
        in text: String,
        font: NSFont,
        maxLineWidth: CGFloat
    ) -> VisibleTextLineEstimate {
        let lineText = lastExplicitLine(in: text)
        guard !lineText.isEmpty else {
            return VisibleTextLineEstimate(width: 0, lineIndex: 0)
        }

        let attributedText = NSAttributedString(
            string: lineText,
            attributes: [.font: font]
        )
        let typesetter = CTTypesetterCreateWithAttributedString(attributedText)
        let textLength = attributedText.length
        let availableWidth = max(1, maxLineWidth)
        var offset = 0
        var lineIndex = 0
        var lastLineWidth: CGFloat = 0

        while offset < textLength {
            let suggestedLength = CTTypesetterSuggestLineBreak(
                typesetter,
                offset,
                Double(availableWidth)
            )
            let lineLength = max(1, suggestedLength)
            let clampedLength = min(lineLength, textLength - offset)
            let line = CTTypesetterCreateLine(
                typesetter,
                CFRange(location: offset, length: clampedLength)
            )
            lastLineWidth = ceil(CGFloat(CTLineGetTypographicBounds(
                line,
                nil,
                nil,
                nil
            )))
            offset += clampedLength
            if offset < textLength {
                lineIndex += 1
            }
        }

        return VisibleTextLineEstimate(
            width: min(lastLineWidth, availableWidth),
            lineIndex: lineIndex
        )
    }

    private static func lastExplicitLine(in text: String) -> String {
        if let lastNewline = text.lastIndex(where: { $0 == "\n" || $0 == "\r" }) {
            return String(text[text.index(after: lastNewline)...])
        }
        return text
    }
}
