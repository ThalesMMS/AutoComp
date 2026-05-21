import ApplicationServices
import AppKit
import Foundation

struct AXHelper {
    func focusedElement(in appElement: AXUIElement) -> AXUIElement? {
        var focusedRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedRef
        )
        guard status == .success, let focusedRef else {
            return nil
        }
        return (focusedRef as! AXUIElement)
    }

    func childElements(for element: AXUIElement) -> [AXUIElement] {
        var childrenRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(
            element,
            kAXChildrenAttribute as CFString,
            &childrenRef
        )
        guard status == .success,
              let childrenRef else {
            return []
        }

        if let children = childrenRef as? [AXUIElement] {
            return children
        }

        guard let values = childrenRef as? [Any] else {
            return []
        }
        return values.map { $0 as! AXUIElement }
    }

    func firstDescendant(
        of element: AXUIElement,
        maxDepth: Int = 10,
        maxVisited: Int = 700,
        matching predicate: (AXUIElement) -> Bool
    ) -> AXUIElement? {
        var queue: [(element: AXUIElement, depth: Int)] = [(element, 0)]
        var seen = Set<UInt>()
        var visited = 0

        while !queue.isEmpty, visited < maxVisited {
            let next = queue.removeFirst()
            let opaque = Unmanaged.passUnretained(next.element).toOpaque()
            let key = UInt(bitPattern: opaque)
            guard seen.insert(key).inserted else {
                continue
            }

            visited += 1
            if predicate(next.element) {
                return next.element
            }

            guard next.depth < maxDepth else {
                continue
            }

            for child in childElements(for: next.element) {
                queue.append((child, next.depth + 1))
            }
        }
        return nil
    }

    func resolvedFocusedElement(from element: AXUIElement) -> AXUIElement {
        var current = element
        for _ in 0..<6 {
            guard let nested = focusedElement(in: current) else {
                return current
            }

            if Unmanaged.passUnretained(current).toOpaque() == Unmanaged.passUnretained(nested).toOpaque() {
                return current
            }
            current = nested
        }
        return current
    }

    func isSecureField(_ element: AXUIElement) -> Bool {
        let role = stringAttribute(kAXRoleAttribute, from: element) ?? ""
        let subrole = stringAttribute(kAXSubroleAttribute, from: element) ?? ""
        return role.localizedCaseInsensitiveContains("Secure")
            || subrole.localizedCaseInsensitiveContains("Secure")
    }

    func readableText(from element: AXUIElement) -> String? {
        stringAttribute(kAXValueAttribute, from: element)
            ?? stringAttribute(kAXSelectedTextAttribute, from: element)
    }

    func textBeforeCursor(
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

    func prefixRange(endingAt location: Int) -> CFRange {
        CFRange(location: 0, length: max(0, location))
    }

    func numberOfCharacters(from element: AXUIElement) -> Int? {
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

    func stringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
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

    func stringListAttribute(_ attribute: String, from element: AXUIElement) -> [String] {
        var value: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, attribute as CFString, &value)
        guard status == .success,
              let values = value as? [Any] else {
            return []
        }

        return values.compactMap { $0 as? String }
    }

    func selectedRange(from element: AXUIElement) -> NSRange? {
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

    func caretRect(for element: AXUIElement, selectedRange: NSRange?) -> CGRect? {
        guard let selectedRange else {
            return nil
        }

        return bounds(for: element, range: CFRange(location: selectedRange.location, length: 0))
    }

    func previousGlyphRect(for element: AXUIElement, selectedRange: NSRange?) -> CGRect? {
        guard let selectedRange,
              selectedRange.length == 0,
              selectedRange.location > 0 else {
            return nil
        }

        return bounds(for: element, range: CFRange(location: selectedRange.location - 1, length: 1))
    }

    func nextGlyphRect(for element: AXUIElement, selectedRange: NSRange?, textLength: Int) -> CGRect? {
        guard let selectedRange,
              selectedRange.length == 0,
              selectedRange.location < textLength else {
            return nil
        }

        return bounds(for: element, range: CFRange(location: selectedRange.location, length: 1))
    }

    func elementRect(for element: AXUIElement) -> CGRect? {
        guard let position = pointAttribute(kAXPositionAttribute, from: element),
              let size = sizeAttribute(kAXSizeAttribute, from: element) else {
            return nil
        }
        return CGRect(origin: position, size: size)
    }

    func ancestorContentRect(for element: AXUIElement) -> CGRect? {
        var current = element
        for _ in 0..<10 {
            if let rect = elementRect(for: current),
               rect.width >= 300,
               rect.height >= 100 {
                return rect
            }

            guard let parent = parentElement(for: current) else {
                return nil
            }
            current = parent
        }
        return nil
    }

    func parentElement(for element: AXUIElement) -> AXUIElement? {
        var parentRef: CFTypeRef?
        let status = AXUIElementCopyAttributeValue(element, kAXParentAttribute as CFString, &parentRef)
        guard status == .success, let parentRef else {
            return nil
        }
        return (parentRef as! AXUIElement)
    }

    func pointAttribute(_ attribute: String, from element: AXUIElement) -> CGPoint? {
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

    func sizeAttribute(_ attribute: String, from element: AXUIElement) -> CGSize? {
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

    func bounds(for element: AXUIElement, range: CFRange) -> CGRect? {
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

    func stringForRange(from element: AXUIElement, range: CFRange) -> String? {
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
}
