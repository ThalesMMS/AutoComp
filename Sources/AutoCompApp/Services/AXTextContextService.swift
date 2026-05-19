import ApplicationServices
import AppKit
import AutoCompCore
import Foundation
import Vision

enum AXTextContextError: LocalizedError {
    case accessibilityNotTrusted
    case noFrontmostApplication
    case noFocusedElement
    case secureOrUnsupportedField
    case noReadableText

    var errorDescription: String? {
        switch self {
        case .accessibilityNotTrusted:
            return "Accessibility permission is required for autocomplete."
        case .noFrontmostApplication:
            return "No frontmost app is available."
        case .noFocusedElement:
            return "No focused text field is available."
        case .secureOrUnsupportedField:
            return "The focused field is secure or unsupported."
        case .noReadableText:
            return "The focused text field did not expose readable text."
        }
    }
}

final class AXTextContextService: TextContextProvider, @unchecked Sendable {
    private let browserResolver = BrowserContextResolver()
    private let screenOCRStateLock = NSLock()
    private var lastScreenOCRStableContext: ScreenOCRFallbackContext?
    private var lastScreenOCRRawText: String?
    private var repeatedScreenOCRRawTextCount = 0

    func currentContext() async throws -> TextContext {
        guard AXIsProcessTrusted() else {
            throw AXTextContextError.accessibilityNotTrusted
        }

        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier else {
            throw AXTextContextError.noFrontmostApplication
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var focusedRef: CFTypeRef?
        let focusedStatus = AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedRef)

        guard focusedStatus == .success, let focused = focusedRef else {
            throw AXTextContextError.noFocusedElement
        }

        let focusedElement = resolvedFocusedElement(from: focused as! AXUIElement)
        guard !isSecureField(focusedElement) else {
            throw AXTextContextError.secureOrUnsupportedField
        }

        var domain = browserResolver.activeDomain(for: bundleID)
        let isGoogleDocsElement = isGoogleDocsEditingElement(focusedElement) || hasGoogleDocsDocumentAncestor(focusedElement)
        let isCodexComposerElement = isCodexComposerElement(focusedElement, bundleID: bundleID)
        if domain == nil, bundleID == "com.google.Chrome", isGoogleDocsElement {
            domain = "docs.google.com"
        }
        var selectedRange = selectedRange(from: focusedElement)
        let fullText = readableText(from: focusedElement)
        let textLength = numberOfCharacters(from: focusedElement)
            ?? fullText.map { ($0 as NSString).length }
            ?? selectedRange.map { $0.location + $0.length }
            ?? 0

        var textBeforeCursor = textBeforeCursor(
            from: focusedElement,
            selectedRange: selectedRange,
            fullText: fullText
        )

        var focusedElementRect = elementRect(for: focusedElement)
        var caretRect = caretRect(for: focusedElement, selectedRange: selectedRange)
        var previousGlyphRect = previousGlyphRect(for: focusedElement, selectedRange: selectedRange)
        var nextGlyphRect = nextGlyphRect(for: focusedElement, selectedRange: selectedRange, textLength: textLength)
        var lineReferenceRect = previousGlyphRect
        var captureSources: Set<TextCaptureSource> = [.accessibility]

        if let codexCaretRect = codexProseMirrorLineCaretRect(
            bundleID: bundleID,
            isCodexComposerElement: isCodexComposerElement,
            text: textBeforeCursor,
            selectedRange: selectedRange,
            focusedElementRect: focusedElementRect,
            caretRect: caretRect,
            previousGlyphRect: previousGlyphRect
        ) {
            caretRect = codexCaretRect
            previousGlyphRect = nil
            nextGlyphRect = nil
            lineReferenceRect = codexCaretRect
            GeometryDebug.log("ax-fallback source=codex-prosemirror-line caretRect=\(codexCaretRect) focusedElementRect=\(String(describing: focusedElementRect))")
        } else if let googleDocsCaretRect = googleDocsAXLineCaretRect(
            bundleID: bundleID,
            domain: domain,
            isGoogleDocsElement: isGoogleDocsElement,
            text: textBeforeCursor,
            focusedElementRect: focusedElementRect,
            caretRect: caretRect,
            previousGlyphRect: previousGlyphRect
        ) {
            caretRect = googleDocsCaretRect
            previousGlyphRect = nil
            nextGlyphRect = nil
            lineReferenceRect = googleDocsCaretRect
            GeometryDebug.log("ax-fallback source=google-docs-braille-line caretRect=\(googleDocsCaretRect) focusedElementRect=\(String(describing: focusedElementRect))")
        } else if shouldUseScreenOCRFallback(
            bundleID: bundleID,
            domain: domain,
            isGoogleDocsElement: isGoogleDocsElement,
            text: textBeforeCursor,
            focusedElementRect: focusedElementRect,
            caretRect: caretRect,
            previousGlyphRect: previousGlyphRect
        ),
           let authoritativeText = textBeforeCursor,
           let fallback = screenOCRFallbackContext(
            searchRect: ancestorContentRect(for: focusedElement),
            authoritativeText: authoritativeText
           ) {
            textBeforeCursor = fallback.textBeforeCursor
            selectedRange = NSRange(location: (fallback.textBeforeCursor as NSString).length, length: 0)
            focusedElementRect = fallback.focusedElementRect
            caretRect = fallback.caretRect
            previousGlyphRect = fallback.previousGlyphRect
            nextGlyphRect = nil
            lineReferenceRect = fallback.previousGlyphRect
            captureSources.insert(.screenOCR)
            GeometryDebug.log("ax-fallback source=screenOCR text=\(fallback.textBeforeCursor) focusedElementRect=\(fallback.focusedElementRect) caretRect=\(fallback.caretRect)")
        }

        guard let textBeforeCursor else {
            GeometryDebug.log("ax rejected reason=no-readable-text role=\(stringAttribute(kAXRoleAttribute, from: focusedElement) ?? "nil") subrole=\(stringAttribute(kAXSubroleAttribute, from: focusedElement) ?? "nil") selectedRange=\(String(describing: selectedRange)) textLength=\(textLength)")
            throw AXTextContextError.noReadableText
        }

        GeometryDebug.log(
            "ax app=\(app.localizedName ?? bundleID) bundle=\(bundleID) domain=\(domain ?? "nil") selectedRange=\(String(describing: selectedRange)) focusedElementRect=\(String(describing: focusedElementRect)) caretRect=\(String(describing: caretRect)) previousGlyphRect=\(String(describing: previousGlyphRect)) nextGlyphRect=\(String(describing: nextGlyphRect))"
        )

        return TextContext(
            app: AppIdentity(
                bundleID: bundleID,
                displayName: app.localizedName ?? bundleID,
                processID: app.processIdentifier
            ),
            domain: domain,
            focusedElementID: "\(app.processIdentifier)-\(Unmanaged.passUnretained(focusedElement).toOpaque())",
            textBeforeCursor: textBeforeCursor,
            selectedRange: selectedRange,
            caretRect: caretRect,
            focusedElementRect: focusedElementRect,
            previousGlyphRect: previousGlyphRect,
            nextGlyphRect: nextGlyphRect,
            lineReferenceRect: lineReferenceRect,
            languageHint: Locale.current.language.languageCode?.identifier,
            captureSources: captureSources
        )
    }

    private func resolvedFocusedElement(from element: AXUIElement) -> AXUIElement {
        var current = element
        for _ in 0..<6 {
            var nestedRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXFocusedUIElementAttribute as CFString, &nestedRef) == .success,
                  let nestedRef else {
                return current
            }

            let nested = nestedRef as! AXUIElement
            if Unmanaged.passUnretained(current).toOpaque() == Unmanaged.passUnretained(nested).toOpaque() {
                return current
            }
            current = nested
        }
        return current
    }

    private func isSecureField(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(kAXRoleAttribute, from: element) ?? ""
        let subrole = stringAttribute(kAXSubroleAttribute, from: element) ?? ""
        return role.localizedCaseInsensitiveContains("Secure")
            || subrole.localizedCaseInsensitiveContains("Secure")
    }

    private func readableText(from element: AXUIElement) -> String? {
        stringAttribute(kAXValueAttribute, from: element)
            ?? stringAttribute(kAXSelectedTextAttribute, from: element)
    }

    private func textBeforeCursor(
        from element: AXUIElement,
        selectedRange: NSRange?,
        fullText: String?
    ) -> String? {
        guard let selectedRange,
              selectedRange.location != NSNotFound else {
            return fullText
        }

        if let rangedPrefix = stringForRange(
            from: element,
            range: prefixRange(endingAt: selectedRange.location)
        ) {
            return rangedPrefix
        }

        guard let fullText else {
            return nil
        }

        let textLength = (fullText as NSString).length
        guard selectedRange.location <= textLength else {
            return fullText
        }
        return (fullText as NSString).substring(to: selectedRange.location)
    }

    private func prefixRange(endingAt location: Int) -> CFRange {
        CFRange(location: 0, length: max(0, location))
    }

    private func numberOfCharacters(from element: AXUIElement) -> Int? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXNumberOfCharactersAttribute as CFString, &value)
        guard status == .success, let value else {
            return nil
        }

        if let number = value as? NSNumber {
            return number.intValue
        }
        return nil
    }

    private func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success, let value else {
            return nil
        }

        if let string = value as? String {
            return string
        }

        if let attributedString = value as? NSAttributedString {
            return attributedString.string
        }

        return nil
    }

    private func selectedRange(from element: AXUIElement) -> NSRange? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXSelectedTextRangeAttribute as CFString, &value)
        guard status == .success, let axValue = value else {
            return nil
        }

        var range = CFRange()
        if AXValueGetValue(axValue as! AXValue, .cfRange, &range) {
            return NSRange(location: range.location, length: range.length)
        }

        return nil
    }

    private func caretRect(for element: AXUIElement, selectedRange: NSRange?) -> CGRect? {
        guard let selectedRange else {
            return nil
        }

        return bounds(for: element, range: CFRange(location: selectedRange.location, length: 0))
    }

    private func previousGlyphRect(for element: AXUIElement, selectedRange: NSRange?) -> CGRect? {
        guard let selectedRange,
              selectedRange.length == 0,
              selectedRange.location > 0 else {
            return nil
        }

        return bounds(for: element, range: CFRange(location: selectedRange.location - 1, length: 1))
    }

    private func nextGlyphRect(for element: AXUIElement, selectedRange: NSRange?, textLength: Int) -> CGRect? {
        guard let selectedRange,
              selectedRange.length == 0,
              selectedRange.location < textLength else {
            return nil
        }

        return bounds(for: element, range: CFRange(location: selectedRange.location, length: 1))
    }

    private func elementRect(for element: AXUIElement) -> CGRect? {
        guard let position = pointAttribute(kAXPositionAttribute, from: element),
              let size = sizeAttribute(kAXSizeAttribute, from: element) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    private func ancestorContentRect(for element: AXUIElement) -> CGRect? {
        var current = element
        for _ in 0..<10 {
            if let rect = elementRect(for: current),
               rect.width >= 300,
               rect.height >= 100 {
                return rect
            }

            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parentRef else {
                return nil
            }
            current = parentRef as! AXUIElement
        }
        return nil
    }

    private func pointAttribute(_ attribute: String, from element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success, let value else {
            return nil
        }

        var point = CGPoint.zero
        if AXValueGetValue(value as! AXValue, .cgPoint, &point) {
            return point
        }
        return nil
    }

    private func sizeAttribute(_ attribute: String, from element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success, let value else {
            return nil
        }

        var size = CGSize.zero
        if AXValueGetValue(value as! AXValue, .cgSize, &size) {
            return size
        }
        return nil
    }

    private func bounds(for element: AXUIElement, range: CFRange) -> CGRect? {
        var cfRange = range
        guard let axRange = AXValueCreate(.cfRange, &cfRange) else {
            return nil
        }

        var boundsRef: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXBoundsForRangeParameterizedAttribute as CFString,
            axRange,
            &boundsRef
        )

        guard status == .success, let boundsRef else {
            return nil
        }

        var rect = CGRect.zero
        if AXValueGetValue(boundsRef as! AXValue, .cgRect, &rect) {
            if rect.width == 0 && rect.height == 0 && rect.minX == 0 && rect.minY == 0 {
                return nil
            }
            return rect
        }

        return nil
    }

    private func stringForRange(from element: AXUIElement, range: CFRange) -> String? {
        guard range.location >= 0, range.length >= 0 else {
            return nil
        }

        var cfRange = range
        guard let axRange = AXValueCreate(.cfRange, &cfRange) else {
            return nil
        }

        var value: CFTypeRef?
        let status = AXUIElementCopyParameterizedAttributeValue(
            element,
            kAXStringForRangeParameterizedAttribute as CFString,
            axRange,
            &value
        )

        guard status == .success, let value else {
            return nil
        }
        if let string = value as? String {
            return string
        }
        if let attributedString = value as? NSAttributedString {
            return attributedString.string
        }
        return nil
    }

    private func shouldUseScreenOCRFallback(
        bundleID: String,
        domain: String?,
        isGoogleDocsElement: Bool,
        text: String?,
        focusedElementRect: CGRect?,
        caretRect: CGRect?,
        previousGlyphRect: CGRect?
    ) -> Bool {
        guard bundleID == "com.google.Chrome",
              domain?.contains("docs.google.com") == true else {
            return false
        }
        guard isGoogleDocsElement else {
            return false
        }
        guard let text, !isWeakText(text) else {
            GeometryDebug.log("ax-fallback skipped reason=google-docs-braille-setup-missing-or-weak-text")
            return false
        }

        return hasWeakTextGeometry(
            focusedElementRect: focusedElementRect,
            caretRect: caretRect,
            previousGlyphRect: previousGlyphRect
        )
    }

    private func codexProseMirrorLineCaretRect(
        bundleID: String,
        isCodexComposerElement: Bool,
        text: String?,
        selectedRange: NSRange?,
        focusedElementRect: CGRect?,
        caretRect: CGRect?,
        previousGlyphRect: CGRect?
    ) -> CGRect? {
        guard bundleID == "com.openai.codex",
              isCodexComposerElement,
              let selectedRange,
              selectedRange.length == 0,
              let text,
              !isWeakText(text),
              hasWeakTextGeometry(
                focusedElementRect: focusedElementRect,
                caretRect: caretRect,
                previousGlyphRect: previousGlyphRect
              ),
              let focusedElementRect,
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
        bundleID: String,
        domain: String?,
        isGoogleDocsElement: Bool,
        text: String?,
        focusedElementRect: CGRect?,
        caretRect: CGRect?,
        previousGlyphRect: CGRect?
    ) -> CGRect? {
        guard bundleID == "com.google.Chrome",
              domain?.contains("docs.google.com") == true,
              isGoogleDocsElement,
              let text,
              !isWeakText(text),
              hasWeakTextGeometry(
                focusedElementRect: focusedElementRect,
                caretRect: caretRect,
                previousGlyphRect: previousGlyphRect
              ),
              let focusedElementRect,
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

    private func isCodexComposerElement(_ element: AXUIElement, bundleID: String) -> Bool {
        guard bundleID == "com.openai.codex",
              stringAttribute(kAXRoleAttribute, from: element) == "AXTextArea" else {
            return false
        }

        let classes = stringListAttribute("AXDOMClassList", from: element)
        return classes.contains("ProseMirror")
            || classes.contains("ProseMirror-focused")
    }

    private func isGoogleDocsEditingElement(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(kAXRoleAttribute, from: element) ?? ""
        let description = stringAttribute(kAXDescriptionAttribute, from: element) ?? ""
        return role == "AXTextArea"
            && (description.localizedCaseInsensitiveContains("document")
                || description.localizedCaseInsensitiveContains("documento")
            )
    }

    private func hasGoogleDocsDocumentAncestor(_ element: AXUIElement) -> Bool {
        var current = element
        for _ in 0..<6 {
            let role = stringAttribute(kAXRoleAttribute, from: current) ?? ""
            let title = stringAttribute(kAXTitleAttribute, from: current) ?? ""
            if role == "AXWebArea",
               title.localizedCaseInsensitiveContains("Google Docs") {
                return true
            }

            var parentRef: CFTypeRef?
            guard AXUIElementCopyAttributeValue(current, kAXParentAttribute as CFString, &parentRef) == .success,
                  let parentRef else {
                return false
            }
            current = parentRef as! AXUIElement
        }
        return false
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

    private func stringListAttribute(_ attribute: String, from element: AXUIElement) -> [String] {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success,
              let values = value as? [Any] else {
            return []
        }

        return values.compactMap { $0 as? String }
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

    private func screenOCRFallbackContext(searchRect: CGRect?, authoritativeText: String) -> ScreenOCRFallbackContext? {
        guard CGPreflightScreenCaptureAccess(),
              let screen = NSScreen.screens.first,
              let image = CGDisplayCreateImage(CGMainDisplayID()) else {
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

        let rawContext = ScreenOCRFallbackContext(
            textBeforeCursor: authoritativeText,
            focusedElementRect: focusedElementRect,
            caretRect: caretRect,
            previousGlyphRect: line.rect
        )
        return stabilizedScreenOCRFallbackContext(rawContext)
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

    private func stabilizedScreenOCRFallbackContext(_ rawContext: ScreenOCRFallbackContext) -> ScreenOCRFallbackContext {
        screenOCRStateLock.lock()
        defer { screenOCRStateLock.unlock() }

        if rawContext.textBeforeCursor == lastScreenOCRRawText {
            repeatedScreenOCRRawTextCount += 1
        } else {
            lastScreenOCRRawText = rawContext.textBeforeCursor
            repeatedScreenOCRRawTextCount = 1
        }

        guard let stableContext = lastScreenOCRStableContext else {
            lastScreenOCRStableContext = rawContext
            return rawContext
        }

        guard isSameOCRLine(rawContext, stableContext) else {
            lastScreenOCRStableContext = rawContext
            return rawContext
        }

        if rawContext.textBeforeCursor == stableContext.textBeforeCursor {
            lastScreenOCRStableContext = rawContext
            return rawContext
        }

        if repeatedScreenOCRRawTextCount >= 2 {
            lastScreenOCRStableContext = rawContext
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
            lastScreenOCRStableContext = stabilized
            return stabilized
        }

        return stableContext.replacingGeometry(from: rawContext)
    }

    private func isSameOCRLine(_ lhs: ScreenOCRFallbackContext, _ rhs: ScreenOCRFallbackContext) -> Bool {
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
}

private struct ScreenOCRFallbackContext {
    let textBeforeCursor: String
    let focusedElementRect: CGRect
    let caretRect: CGRect
    let previousGlyphRect: CGRect

    func replacingTextBeforeCursor(_ textBeforeCursor: String) -> ScreenOCRFallbackContext {
        ScreenOCRFallbackContext(
            textBeforeCursor: textBeforeCursor,
            focusedElementRect: focusedElementRect,
            caretRect: caretRect,
            previousGlyphRect: previousGlyphRect
        )
    }

    func replacingGeometry(from other: ScreenOCRFallbackContext) -> ScreenOCRFallbackContext {
        ScreenOCRFallbackContext(
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
