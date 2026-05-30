import AppKit

// TextContext and CaretGeometryQuality live in AutoCompApp; explicit import required after file split.
import AutoCompCore

struct OverlayGeometryValidation: Equatable {
    let focusedElementRect: CGRect?
    let caretRect: CGRect?
    let previousGlyphRect: CGRect?
    let nextGlyphRect: CGRect?
    let lineReferenceRect: CGRect?
}

struct OverlayGeometryValidator {
    private let screenFrame: CGRect
    private let visibleFrame: CGRect
    private let screenFrames: [CGRect]
    private let focusedElementTolerance: CGFloat
    private let screenTolerance: CGFloat

    init(
        screenFrame: CGRect,
        visibleFrame: CGRect,
        screenFrames: [CGRect] = [],
        focusedElementTolerance: CGFloat = 12,
        screenTolerance: CGFloat = 12
    ) {
        self.screenFrame = screenFrame
        self.visibleFrame = visibleFrame
        self.screenFrames = screenFrames.isEmpty ? [screenFrame] : screenFrames
        self.focusedElementTolerance = focusedElementTolerance
        self.screenTolerance = screenTolerance
    }

    func validate(context: TextContext) -> OverlayGeometryValidation {
        let focusedElementRect = validatedElementRect(context.focusedElementRect)
        let caretRect = validatedMetricRect(
            context.caretRect,
            name: "caret",
            quality: context.caretGeometryQuality,
            selectedRange: context.selectedRange,
            focusedElementRect: focusedElementRect
        )
        let previousGlyphRect = validatedMetricRect(
            context.previousGlyphRect ?? context.lineReferenceRect,
            name: "previous-glyph",
            quality: context.caretGeometryQuality,
            selectedRange: context.selectedRange,
            focusedElementRect: focusedElementRect
        )
        let nextGlyphRect = validatedMetricRect(
            context.nextGlyphRect,
            name: "next-glyph",
            quality: context.caretGeometryQuality,
            selectedRange: context.selectedRange,
            focusedElementRect: focusedElementRect
        )
        let lineReferenceRect = validatedMetricRect(
            context.lineReferenceRect,
            name: "line-reference",
            quality: context.caretGeometryQuality,
            selectedRange: context.selectedRange,
            focusedElementRect: focusedElementRect
        )
        return OverlayGeometryValidation(
            focusedElementRect: focusedElementRect,
            caretRect: caretRect,
            previousGlyphRect: previousGlyphRect,
            nextGlyphRect: nextGlyphRect,
            lineReferenceRect: lineReferenceRect
        )
    }

    private func validatedElementRect(_ rawRect: CGRect?) -> CGRect? {
        guard let rawRect,
              rawRect.isFiniteAndNonEmpty,
              rawRect.width <= screenFrame.width * 1.2,
              rawRect.height <= screenFrame.height * 1.2 else {
            return nil
        }

        guard !isSuspiciousZeroOrigin(rawRect) else {
            GeometryDebug.log("overlay-geometry rejected-zero-origin metric=focused-element raw=\(rawRect)")
            return nil
        }

        guard let converted = convertedRect(rawRect, name: "focused-element") else {
            return nil
        }
        GeometryDebug.log("overlay-geometry accepted metric=focused-element converted=\(converted)")
        return converted
    }

    private func validatedMetricRect(
        _ rawRect: CGRect?,
        name: String,
        quality: CaretGeometryQuality,
        selectedRange: NSRange?,
        focusedElementRect: CGRect?
    ) -> CGRect? {
        guard let rawRect else {
            return nil
        }

        guard rawRect.isFiniteAndNonEmpty || isCollapsedCaretMetric(rawRect, metricName: name) else {
            GeometryDebug.log("overlay-geometry rejected-empty metric=\(name) raw=\(rawRect)")
            return nil
        }

        guard !isSuspiciousZeroOrigin(rawRect) else {
            GeometryDebug.log("overlay-geometry rejected-zero-origin metric=\(name) raw=\(rawRect)")
            return nil
        }

        let normalizedRawRect = normalizedMetricRect(
            rawRect,
            metricName: name,
            quality: quality,
            selectedRange: selectedRange
        )

        guard metricWithinQualityCaps(normalizedRawRect, metricName: name, quality: quality) else {
            GeometryDebug.log("overlay-geometry rejected-absurd-size metric=\(name) raw=\(rawRect) normalized=\(normalizedRawRect) quality=\(quality.rawValue)")
            return nil
        }

        guard let converted = convertedRect(normalizedRawRect, name: name) else {
            return nil
        }

        if let focusedElementRect,
           shouldRequireFocusProximity(metricName: name, quality: quality) {
            let expandedFocus = focusedElementRect.insetBy(dx: -focusedElementTolerance, dy: -focusedElementTolerance)
            guard expandedFocus.intersects(converted) || expandedFocus.contains(CGPoint(x: converted.midX, y: converted.midY)) else {
                GeometryDebug.log("overlay-geometry rejected-far-from-field metric=\(name) raw=\(rawRect) converted=\(converted) focused=\(focusedElementRect) quality=\(quality.rawValue)")
                return nil
            }
        }

        if normalizedRawRect != rawRect {
            GeometryDebug.log("overlay-geometry normalized metric=\(name) raw=\(rawRect) normalized=\(normalizedRawRect) converted=\(converted) quality=\(quality.rawValue)")
        } else {
            GeometryDebug.log("overlay-geometry accepted metric=\(name) converted=\(converted) quality=\(quality.rawValue)")
        }
        return converted
    }

    private func convertedRect(_ rawRect: CGRect, name: String) -> CGRect? {
        for candidate in rawRectCandidates(rawRect) {
            let converted = OverlayGeometry.appKitRect(accessibilityRect: candidate.rect, screenFrame: screenFrame)
            guard converted.isFiniteAndNonEmpty else {
                continue
            }
            if intersectsAnyScreen(converted) {
                if let reason = candidate.reason {
                    GeometryDebug.log("overlay-geometry normalized metric=\(name) reason=\(reason) raw=\(rawRect) normalized=\(candidate.rect) converted=\(converted)")
                }
                return converted
            }
        }

        let converted = OverlayGeometry.appKitRect(accessibilityRect: rawRect, screenFrame: screenFrame)
        GeometryDebug.log("overlay-geometry rejected-outside-screen metric=\(name) raw=\(rawRect) converted=\(converted)")
        return nil
    }

    private func rawRectCandidates(_ rawRect: CGRect) -> [(rect: CGRect, reason: String?)] {
        var candidates: [(rect: CGRect, reason: String?)] = [(rawRect, nil)]
        for scale in [CGFloat(2), CGFloat(3)] {
            let scaled = CGRect(
                x: rawRect.minX / scale,
                y: rawRect.minY / scale,
                width: rawRect.width / scale,
                height: rawRect.height / scale
            )
            candidates.append((scaled, "physical-to-points-\(Int(scale))x"))
        }
        return candidates
    }

    private func intersectsAnyScreen(_ rect: CGRect) -> Bool {
        let expanded = rect.insetBy(dx: -screenTolerance, dy: -screenTolerance)
        return screenFrames.contains { screenFrame in
            screenFrame.insetBy(dx: -screenTolerance, dy: -screenTolerance).intersects(expanded)
        } || visibleFrame.insetBy(dx: -screenTolerance, dy: -screenTolerance).intersects(expanded)
    }

    private func isSuspiciousZeroOrigin(_ rect: CGRect) -> Bool {
        abs(rect.minX) < 0.5 && abs(rect.minY) < 0.5
    }

    private func isCollapsedCaretMetric(_ rect: CGRect, metricName: String) -> Bool {
        guard metricName == "caret" || metricName == "previous-glyph" else {
            return false
        }
        return rect.minX.isFinite
            && rect.minY.isFinite
            && rect.width.isFinite
            && rect.height.isFinite
            && rect.width == 0
            && rect.height > 0
    }

    private func normalizedMetricRect(
        _ rect: CGRect,
        metricName: String,
        quality: CaretGeometryQuality,
        selectedRange: NSRange?
    ) -> CGRect {
        if isCollapsedCaretMetric(rect, metricName: metricName) {
            return CGRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height)
        }

        if metricName == "caret",
           selectedRange?.length == 0,
           rect.width > max(CGFloat(4), rect.height * 0.35),
           quality != .elementFrame,
           quality != .unavailable {
            return CGRect(x: rect.minX, y: rect.minY, width: 1, height: rect.height)
        }

        return rect
    }

    private func metricWithinQualityCaps(
        _ rect: CGRect,
        metricName: String,
        quality: CaretGeometryQuality
    ) -> Bool {
        let maximumHeight: CGFloat
        switch quality {
        case .directCaret, .glyph, .lineMetric, .screenOCR:
            maximumHeight = max(120, screenFrame.height * 0.25)
        case .elementFrame, .unavailable:
            maximumHeight = max(80, screenFrame.height * 0.12)
        }

        let maximumWidth = metricName == "caret"
            ? max(CGFloat(24), screenFrame.width * 0.05)
            : screenFrame.width
        return rect.width <= maximumWidth && rect.height <= maximumHeight
    }

    private func shouldRequireFocusProximity(metricName: String, quality: CaretGeometryQuality) -> Bool {
        guard metricName != "focused-element" else {
            return false
        }
        switch quality {
        case .screenOCR:
            return false
        case .directCaret, .glyph, .lineMetric, .elementFrame, .unavailable:
            return true
        }
    }
}
