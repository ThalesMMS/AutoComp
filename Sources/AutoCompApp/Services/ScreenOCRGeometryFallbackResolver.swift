import AppKit
import Foundation
import ScreenCaptureKit
import Vision

final class ScreenOCRGeometryFallbackResolver: @unchecked Sendable {
    private let stateLock = NSLock()
    private var lastStableContext: ScreenOCRGeometryFallback?
    private var lastRawText: String?
    private var repeatedRawTextCount = 0

    func resolve(searchRect: CGRect?, authoritativeText: String) async -> ScreenOCRGeometryFallback? {
        guard CGPreflightScreenCaptureAccess(),
              let screen = NSScreen.screens.first,
              let image = await captureScreenImage(in: screen.frame) else {
            return nil
        }

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["pt-BR", "en-US"]

        let handler = VNImageRequestHandler(cgImage: image)
        do {
            try handler.perform([request])
        } catch {
            return nil
        }

        let screenFrame = screen.frame
        let candidates = (request.results ?? []).compactMap { observation -> ScreenOCRLine? in
            guard let candidate = observation.topCandidates(1).first else {
                return nil
            }
            let text = candidate.string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return nil
            }

            let rect = accessibilityRect(fromVisionBoundingBox: observation.boundingBox, screenFrame: screenFrame)
            if let searchRect,
               !searchRect.insetBy(dx: -24, dy: -24).contains(CGPoint(x: rect.midX, y: rect.midY)) {
                return nil
            }

            guard rect.minX > 340,
                  rect.minY > 300,
                  rect.minY < screenFrame.height * 0.85,
                  rect.height >= 8,
                  rect.height <= 36,
                  rect.width >= 12 else {
                return nil
            }
            return ScreenOCRLine(text: text, rect: rect)
        }

        guard let line = mergedOCRLines(from: candidates).sorted(by: { lhs, rhs in
            if abs(lhs.rect.minY - rhs.rect.minY) > 8 {
                return lhs.rect.minY < rhs.rect.minY
            }
            return lhs.rect.minX < rhs.rect.minX
        }).last else {
            return nil
        }

        let defaultCaretRect = CGRect(
            x: line.rect.maxX,
            y: line.rect.minY,
            width: 1,
            height: line.rect.height
        )
        let caretRect = detectedCaretRect(
            near: line.rect,
            in: image,
            screenFrame: screenFrame,
            searchRect: searchRect
        ) ?? defaultCaretRect
        let focusedElementRect = line.rect.insetBy(dx: -8, dy: -8).union(
            CGRect(
                x: line.rect.minX,
                y: line.rect.minY,
                width: max(caretRect.maxX - line.rect.minX + 320, 360),
                height: max(line.rect.height + 16, 32)
            )
        )

        let rawContext = ScreenOCRGeometryFallback(
            textBeforeCursor: authoritativeText,
            focusedElementRect: focusedElementRect,
            caretRect: caretRect,
            previousGlyphRect: line.rect
        )
        return stabilizedContext(rawContext)
    }

    private func mergedOCRLines(from candidates: [ScreenOCRLine]) -> [ScreenOCRLine] {
        let sortedCandidates = candidates.sorted {
            if abs($0.rect.midY - $1.rect.midY) > 8 {
                return $0.rect.midY < $1.rect.midY
            }
            return $0.rect.minX < $1.rect.minX
        }

        var rows: [[ScreenOCRLine]] = []
        for candidate in sortedCandidates {
            if let index = rows.firstIndex(where: { row in
                guard let first = row.first else { return false }
                let tolerance = max(CGFloat(8), min(first.rect.height, candidate.rect.height) * 0.85)
                return abs(first.rect.midY - candidate.rect.midY) <= tolerance
            }) {
                rows[index].append(candidate)
            } else {
                rows.append([candidate])
            }
        }

        return rows.compactMap { row in
            let ordered = row.sorted { $0.rect.minX < $1.rect.minX }
            guard let first = ordered.first else {
                return nil
            }
            let text = ordered.map(\.text).joined(separator: " ")
            let rect = ordered.dropFirst().reduce(first.rect) { $0.union($1.rect) }
            return ScreenOCRLine(text: text, rect: rect)
        }
    }

    private func stabilizedContext(_ rawContext: ScreenOCRGeometryFallback) -> ScreenOCRGeometryFallback {
        stateLock.lock()
        defer { stateLock.unlock() }

        if rawContext.textBeforeCursor == lastRawText {
            repeatedRawTextCount += 1
        } else {
            lastRawText = rawContext.textBeforeCursor
            repeatedRawTextCount = 1
        }

        guard let stableContext = lastStableContext else {
            lastStableContext = rawContext
            return rawContext
        }

        guard isSameOCRLine(rawContext, stableContext) else {
            lastStableContext = rawContext
            return rawContext
        }

        if rawContext.textBeforeCursor == stableContext.textBeforeCursor {
            lastStableContext = rawContext
            return rawContext
        }

        if repeatedRawTextCount >= 2 {
            lastStableContext = rawContext
            return rawContext
        }

        let prefix = commonPrefix(rawContext.textBeforeCursor, stableContext.textBeforeCursor)
        let rawLength = (rawContext.textBeforeCursor as NSString).length
        let stableLength = (stableContext.textBeforeCursor as NSString).length
        let prefixLength = (prefix as NSString).length
        let longestLength = max(rawLength, stableLength)
        if prefixLength >= 4,
           longestLength - prefixLength <= 4 {
            let stabilized = rawContext.replacingTextBeforeCursor(prefix)
            lastStableContext = stabilized
            return stabilized
        }

        return stableContext.replacingGeometry(from: rawContext)
    }

    private func isSameOCRLine(_ lhs: ScreenOCRGeometryFallback, _ rhs: ScreenOCRGeometryFallback) -> Bool {
        abs(lhs.caretRect.midX - rhs.caretRect.midX) <= 18
            && abs(lhs.caretRect.midY - rhs.caretRect.midY) <= 8
    }

    private func commonPrefix(_ lhs: String, _ rhs: String) -> String {
        var result = ""
        var leftIndex = lhs.startIndex
        var rightIndex = rhs.startIndex
        while leftIndex < lhs.endIndex,
              rightIndex < rhs.endIndex,
              lhs[leftIndex] == rhs[rightIndex] {
            result.append(lhs[leftIndex])
            leftIndex = lhs.index(after: leftIndex)
            rightIndex = rhs.index(after: rightIndex)
        }
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func accessibilityRect(fromVisionBoundingBox boundingBox: CGRect, screenFrame: CGRect) -> CGRect {
        CGRect(
            x: screenFrame.minX + boundingBox.minX * screenFrame.width,
            y: screenFrame.minY + (1 - boundingBox.maxY) * screenFrame.height,
            width: boundingBox.width * screenFrame.width,
            height: boundingBox.height * screenFrame.height
        )
    }

    private func detectedCaretRect(
        near lineRect: CGRect,
        in image: CGImage,
        screenFrame: CGRect,
        searchRect: CGRect?
    ) -> CGRect? {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let scaleX = CGFloat(bitmap.pixelsWide) / max(1, screenFrame.width)
        let scaleY = CGFloat(bitmap.pixelsHigh) / max(1, screenFrame.height)
        let rightLimit = min(searchRect?.maxX ?? screenFrame.maxX, lineRect.maxX + 120)
        let xStart = max(lineRect.maxX - 2, screenFrame.minX)
        let xEnd = max(xStart, rightLimit)
        let yStart = max(lineRect.minY - 8, screenFrame.minY)
        let yEnd = min(lineRect.maxY + 10, screenFrame.maxY)

        let pxStart = max(0, Int(floor((xStart - screenFrame.minX) * scaleX)))
        let pxEnd = min(bitmap.pixelsWide - 1, Int(ceil((xEnd - screenFrame.minX) * scaleX)))
        let pyStart = max(0, Int(floor((yStart - screenFrame.minY) * scaleY)))
        let pyEnd = min(bitmap.pixelsHigh - 1, Int(ceil((yEnd - screenFrame.minY) * scaleY)))
        guard pxEnd > pxStart, pyEnd > pyStart else {
            return nil
        }

        var bestColumn: Int?
        var bestCount = 0
        let requiredDarkPixels = max(7, Int(Double(pyEnd - pyStart) * 0.45))
        for x in pxStart...pxEnd {
            var darkPixels = 0
            for y in pyStart...pyEnd {
                guard let color = bitmap.colorAt(x: x, y: y) else {
                    continue
                }
                let brightness = (color.redComponent + color.greenComponent + color.blueComponent) / 3
                if color.alphaComponent > 0.4 && brightness < 0.18 {
                    darkPixels += 1
                }
            }

            if darkPixels >= requiredDarkPixels,
               x > (bestColumn ?? pxStart - 1) || darkPixels > bestCount {
                bestColumn = x
                bestCount = darkPixels
            }
        }

        guard let bestColumn else {
            return nil
        }
        guard bestColumn < pxEnd - 3 else {
            return nil
        }

        let caretX = screenFrame.minX + CGFloat(bestColumn) / scaleX
        guard caretX >= lineRect.maxX - 2 else {
            return nil
        }
        return CGRect(x: caretX, y: lineRect.minY, width: 1, height: lineRect.height)
    }

    private func captureScreenImage(in rect: CGRect) async -> CGImage? {
        guard #available(macOS 15.2, *) else {
            return nil
        }
        return await withCheckedContinuation { continuation in
            SCScreenshotManager.captureImage(in: rect) { image, _ in
                continuation.resume(returning: image)
            }
        }
    }
}

struct ScreenOCRGeometryFallback {
    let textBeforeCursor: String
    let focusedElementRect: CGRect
    let caretRect: CGRect
    let previousGlyphRect: CGRect

    func replacingTextBeforeCursor(_ textBeforeCursor: String) -> ScreenOCRGeometryFallback {
        ScreenOCRGeometryFallback(
            textBeforeCursor: textBeforeCursor,
            focusedElementRect: focusedElementRect,
            caretRect: caretRect,
            previousGlyphRect: previousGlyphRect
        )
    }

    func replacingGeometry(from other: ScreenOCRGeometryFallback) -> ScreenOCRGeometryFallback {
        ScreenOCRGeometryFallback(
            textBeforeCursor: textBeforeCursor,
            focusedElementRect: other.focusedElementRect,
            caretRect: other.caretRect,
            previousGlyphRect: other.previousGlyphRect
        )
    }
}

private struct ScreenOCRLine {
    let text: String
    let rect: CGRect
}
