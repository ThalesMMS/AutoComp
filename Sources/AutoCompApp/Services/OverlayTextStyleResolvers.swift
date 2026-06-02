import ApplicationServices
import AppKit
import AutoCompCore
import Foundation

enum TextDirection: Equatable {
    case leftToRight
    case rightToLeft
}

enum TextDirectionDetector {
    static func direction(for text: String) -> TextDirection {
        isRightToLeft(text) ? .rightToLeft : .leftToRight
    }

    static func isRightToLeft(_ text: String) -> Bool {
        for scalar in text.unicodeScalars.reversed() {
            if isStrongRightToLeft(scalar) {
                return true
            }
            if isStrongLeftToRight(scalar) {
                return false
            }
        }
        return false
    }

    private static func isStrongRightToLeft(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value >= 0x0590 && value <= 0x08FF {
            return true
        }
        if value >= 0xFB1D && value <= 0xFDFF {
            return true
        }
        if value >= 0xFE70 && value <= 0xFEFF {
            return true
        }
        return value == 0x200F || value == 0x061C
    }

    private static func isStrongLeftToRight(_ scalar: Unicode.Scalar) -> Bool {
        let value = scalar.value
        if value >= 0x0041 && value <= 0x005A {
            return true
        }
        if value >= 0x0061 && value <= 0x007A {
            return true
        }
        if value >= 0x00C0 && value <= 0x024F {
            return true
        }
        if value >= 0x0370 && value <= 0x03FF {
            return true
        }
        if value >= 0x0400 && value <= 0x04FF {
            return true
        }
        if value >= 0x4E00 && value <= 0x9FFF {
            return true
        }
        return value == 0x200E
    }
}

enum OverlayTextStyleSource: String, Equatable {
    case axAttributedString
    case caretHeightFallback
    case appProfileFallback
    case systemDefault
}

struct ResolvedOverlayTextStyle {
    let font: NSFont
    let textColor: NSColor
    let source: OverlayTextStyleSource
}

struct OverlayStyleProbeRangeResolver {
    static func probeRange(selectedRange: NSRange?, textLength: Int) -> NSRange? {
        guard let selectedRange,
              selectedRange.location != NSNotFound,
              selectedRange.location >= 0 else {
            return nil
        }

        let boundedTextLength = max(0, textLength)
        if selectedRange.length > 0 {
            guard selectedRange.location < boundedTextLength else {
                return nil
            }
            return NSRange(location: selectedRange.location, length: 1)
        }

        if selectedRange.location > 0 {
            return NSRange(location: selectedRange.location - 1, length: 1)
        }

        guard boundedTextLength > 0 else {
            return nil
        }
        return NSRange(location: 0, length: 1)
    }
}

struct OverlayAXTextStyleAttributeParser {
    struct ParsedStyle {
        let font: NSFont?
        let textColor: NSColor?

        var hasResolvedValue: Bool {
            font != nil || textColor != nil
        }
    }

    static func style(from attributedString: NSAttributedString, fallbackFontSize: CGFloat? = nil) -> ParsedStyle? {
        guard attributedString.length > 0 else {
            return nil
        }

        let attributes = attributedString.attributes(at: 0, effectiveRange: nil)
        let parsed = ParsedStyle(
            font: font(from: attributes, fallbackSize: fallbackFontSize),
            textColor: color(from: attributes)
        )
        return parsed.hasResolvedValue ? parsed : nil
    }

    static func font(
        from attributes: [NSAttributedString.Key: Any],
        fallbackSize: CGFloat? = nil
    ) -> NSFont? {
        for key in fontAttributeKeys {
            if let font = font(fromAXFontValue: attributes[key], fallbackSize: fallbackSize) {
                return font
            }
        }
        return nil
    }

    static func font(fromAXFontValue value: Any?, fallbackSize: CGFloat? = nil) -> NSFont? {
        guard let value else {
            return nil
        }

        if let font = value as? NSFont {
            return font
        }

        guard let entries = dictionaryEntries(from: value) else {
            return nil
        }

        let size = validFontSize(
            numericValue(
                for: ["AXFontSize", "NSFontSize", "NSFontSizeAttribute"],
                in: entries
            )
        )
            ?? validFontSize(fallbackSize)
            ?? NSFont.systemFontSize

        if let name = stringValue(
            for: ["AXFontName", "NSFontName", "NSFontNameAttribute", "AXVisibleName"],
            in: entries
        ),
           let font = NSFont(name: name, size: size) {
            return font
        }

        if let family = stringValue(
            for: ["AXFontFamily", "NSFontFamily", "NSFontFamilyAttribute"],
            in: entries
        ),
           let font = NSFontManager.shared.font(
            withFamily: family,
            traits: [],
            weight: 5,
            size: size
           ) {
            return font
        }

        return NSFont.systemFont(ofSize: size)
    }

    static func color(from attributes: [NSAttributedString.Key: Any]) -> NSColor? {
        for key in colorAttributeKeys {
            if let color = color(fromAXColorValue: attributes[key]) {
                return color
            }
        }
        return nil
    }

    static func color(fromAXColorValue value: Any?) -> NSColor? {
        guard let value else {
            return nil
        }

        if let color = value as? NSColor {
            return color
        }

        if let cgColor = cgColor(from: value) {
            return NSColor(cgColor: cgColor) ?? color(fromCGColorComponents: cgColor)
        }

        if let entries = dictionaryEntries(from: value),
           let color = color(from: entries) {
            return color
        }

        if let array = value as? [Any] {
            return color(from: array)
        }
        if let array = value as? NSArray {
            return color(from: array.map { $0 })
        }
        return nil
    }

    private static let fontAttributeKeys: [NSAttributedString.Key] = [
        .font,
        NSAttributedString.Key("AXFont"),
        NSAttributedString.Key("AXFontTextAttribute")
    ]

    private static let colorAttributeKeys: [NSAttributedString.Key] = [
        .foregroundColor,
        NSAttributedString.Key("AXForegroundColor"),
        NSAttributedString.Key("AXForegroundColorTextAttribute")
    ]

    private static func dictionaryEntries(from value: Any) -> [(key: Any, value: Any)]? {
        if let dictionary = value as? [AnyHashable: Any] {
            return dictionary.map { (key: $0.key, value: $0.value) }
        }
        if let dictionary = value as? NSDictionary {
            return dictionary.map { (key: $0.key, value: $0.value) }
        }
        return nil
    }

    private static func stringValue(for keys: Set<String>, in entries: [(key: Any, value: Any)]) -> String? {
        for entry in entries where keys.contains(normalizedKey(entry.key)) {
            if let value = entry.value as? String, !value.isEmpty {
                return value
            }
        }
        return nil
    }

    private static func numericValue(for keys: Set<String>, in entries: [(key: Any, value: Any)]) -> CGFloat? {
        for entry in entries where keys.contains(normalizedKey(entry.key)) {
            if let value = numericValue(entry.value) {
                return value
            }
        }
        return nil
    }

    private static func numericValue(_ value: Any) -> CGFloat? {
        switch value {
        case let number as NSNumber:
            return CGFloat(number.doubleValue)
        case let value as CGFloat:
            return value
        case let value as Double:
            return CGFloat(value)
        case let value as Float:
            return CGFloat(value)
        case let value as Int:
            return CGFloat(value)
        default:
            return nil
        }
    }

    private static func validFontSize(_ size: CGFloat?) -> CGFloat? {
        guard let size,
              size.isFinite,
              size >= 6,
              size <= 96 else {
            return nil
        }
        return size
    }

    private static func normalizedKey(_ key: Any) -> String {
        if let key = key as? String {
            return key
        }
        if let key = key as? NSAttributedString.Key {
            return key.rawValue
        }
        return String(describing: key)
    }

    private static func color(from entries: [(key: Any, value: Any)]) -> NSColor? {
        guard let red = numericValue(for: ["red", "AXRed"], in: entries),
              let green = numericValue(for: ["green", "AXGreen"], in: entries),
              let blue = numericValue(for: ["blue", "AXBlue"], in: entries) else {
            return nil
        }
        let alpha = numericValue(for: ["alpha", "AXAlpha"], in: entries) ?? 1
        return color(red: red, green: green, blue: blue, alpha: alpha)
    }

    private static func color(from values: [Any]) -> NSColor? {
        guard values.count >= 3,
              let red = numericValue(values[0]),
              let green = numericValue(values[1]),
              let blue = numericValue(values[2]) else {
            return nil
        }
        let alpha = values.count >= 4 ? (numericValue(values[3]) ?? 1) : 1
        return color(red: red, green: green, blue: blue, alpha: alpha)
    }

    private static func color(fromCGColorComponents cgColor: CGColor) -> NSColor? {
        guard let components = cgColor.components else {
            return nil
        }
        if components.count >= 3 {
            return color(
                red: components[0],
                green: components[1],
                blue: components[2],
                alpha: components.count >= 4 ? components[3] : cgColor.alpha
            )
        }
        if components.count >= 1 {
            return color(
                red: components[0],
                green: components[0],
                blue: components[0],
                alpha: components.count >= 2 ? components[1] : cgColor.alpha
            )
        }
        return nil
    }

    private static func cgColor(from value: Any) -> CGColor? {
        let cfValue = value as CFTypeRef
        guard CFGetTypeID(cfValue) == CGColor.typeID else {
            return nil
        }
        return unsafeDowncast(cfValue as AnyObject, to: CGColor.self)
    }

    private static func color(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) -> NSColor {
        NSColor(
            srgbRed: normalizedColorComponent(red),
            green: normalizedColorComponent(green),
            blue: normalizedColorComponent(blue),
            alpha: max(0, min(1, alpha))
        )
    }

    private static func normalizedColorComponent(_ value: CGFloat) -> CGFloat {
        guard value.isFinite else {
            return 0
        }
        if value > 1 {
            return max(0, min(1, value / 255))
        }
        return max(0, min(1, value))
    }
}

struct OverlayAXTextStyleProbeResult {
    let attributedString: NSAttributedString
    let range: NSRange
}

protocol OverlayTextStyleProbing {
    func attributedStyle(for context: TextContext) -> OverlayAXTextStyleProbeResult?
}

struct AXOverlayTextStyleProbe: OverlayTextStyleProbing {
    private let axHelper: AXHelper

    init(axHelper: AXHelper = AXHelper()) {
        self.axHelper = axHelper
    }

    func attributedStyle(for context: TextContext) -> OverlayAXTextStyleProbeResult? {
        guard AXIsProcessTrusted(),
              NSWorkspace.shared.frontmostApplication?.processIdentifier == context.app.processID else {
            return nil
        }

        let appElement = AXUIElementCreateApplication(context.app.processID)
        guard let focusedElement = axHelper.focusedElement(in: appElement) else {
            return nil
        }

        let resolvedFocusedElement = axHelper.resolvedFocusedElement(from: focusedElement)
        for element in candidateTextElements(
            focusedElement: resolvedFocusedElement,
            appElement: appElement,
            context: context
        ) {
            let selectedRange = axHelper.selectedRange(from: element) ?? context.selectedRange
            let textLength = textLength(for: element, context: context, selectedRange: selectedRange)
            guard let probeRange = OverlayStyleProbeRangeResolver.probeRange(
                selectedRange: selectedRange,
                textLength: textLength
            ) else {
                continue
            }

            let cfRange = CFRange(location: probeRange.location, length: probeRange.length)
            if let attributedString = axHelper.attributedStringForRange(from: element, range: cfRange),
               attributedString.length > 0 {
                return OverlayAXTextStyleProbeResult(
                    attributedString: attributedString,
                    range: probeRange
                )
            }
        }

        return nil
    }

    private func candidateTextElements(
        focusedElement: AXUIElement,
        appElement: AXUIElement,
        context: TextContext
    ) -> [AXUIElement] {
        var candidates = [focusedElement]
        if context.app.bundleID == "com.google.Chrome" {
            if let descendant = axHelper.firstDescendant(
                of: focusedElement,
                maxDepth: 8,
                maxVisited: 350,
                matching: isReadableTextElement
            ) {
                candidates.append(descendant)
            }
            if let descendant = axHelper.firstDescendant(
                of: appElement,
                maxDepth: 10,
                maxVisited: 700,
                matching: isReadableTextElement
            ) {
                candidates.append(descendant)
            }
        }
        return uniqueElements(candidates)
    }

    private func isReadableTextElement(_ element: AXUIElement) -> Bool {
        if axHelper.readableText(from: element) != nil {
            return true
        }
        if let numberOfCharacters = axHelper.numberOfCharacters(from: element),
           numberOfCharacters > 0 {
            return true
        }
        return axHelper.selectedRange(from: element) != nil
    }

    private func uniqueElements(_ elements: [AXUIElement]) -> [AXUIElement] {
        var seen = Set<UInt>()
        var unique: [AXUIElement] = []
        for element in elements {
            let key = UInt(bitPattern: Unmanaged.passUnretained(element).toOpaque())
            guard seen.insert(key).inserted else {
                continue
            }
            unique.append(element)
        }
        return unique
    }

    private func textLength(
        for element: AXUIElement,
        context: TextContext,
        selectedRange: NSRange?
    ) -> Int {
        if let numberOfCharacters = axHelper.numberOfCharacters(from: element) {
            return numberOfCharacters
        }
        if let text = axHelper.readableText(from: element) {
            return (text as NSString).length
        }

        let beforeLength = (context.textBeforeCursor as NSString).length
        let selectedLength = selectedRange?.length ?? (context.selectedText.map { ($0 as NSString).length } ?? 0)
        let afterLength = context.textAfterCursor.map { ($0 as NSString).length } ?? 0
        let selectedRangeEnd = selectedRange.map { $0.location + $0.length } ?? 0
        return max(beforeLength + selectedLength + afterLength, selectedRangeEnd + afterLength)
    }
}

final class OverlayTextStyleResolver {
    private struct CacheKey: Equatable {
        let bundleID: String
        let processID: Int32
        let focusedElementID: String
        let selectedLocation: Int
        let selectedLength: Int
        let caretHeightBucket: Int

        init(context: TextContext) {
            bundleID = context.app.bundleID
            processID = context.app.processID
            focusedElementID = context.focusedElementID
            selectedLocation = context.selectedRange?.location ?? NSNotFound
            selectedLength = context.selectedRange?.length ?? 0
            caretHeightBucket = Self.caretHeightBucket(for: context)
        }

        private static func caretHeightBucket(for context: TextContext) -> Int {
            let height = OverlayTextStyleResolver.caretHeightSignal(for: context) ?? 0
            return Int((height * 2).rounded())
        }
    }

    private struct CacheEntry {
        let key: CacheKey
        let createdAt: Date
        let style: ResolvedOverlayTextStyle
    }

    private let axProbe: any OverlayTextStyleProbing
    private let cacheTTL: TimeInterval
    private let now: () -> Date
    private var cacheEntry: CacheEntry?
    private var caretFontSizeResolver = GhostFontSizeResolver()

    init(
        axProbe: any OverlayTextStyleProbing = AXOverlayTextStyleProbe(),
        cacheTTL: TimeInterval = 0.35,
        now: @escaping () -> Date = Date.init
    ) {
        self.axProbe = axProbe
        self.cacheTTL = cacheTTL
        self.now = now
    }

    func style(for context: TextContext, appearance: NSAppearance? = nil) -> ResolvedOverlayTextStyle {
        let key = CacheKey(context: context)
        let currentDate = now()
        if let cacheEntry,
           cacheEntry.key == key,
           currentDate.timeIntervalSince(cacheEntry.createdAt) < cacheTTL {
            return cacheEntry.style
        }

        let style = resolveStyle(for: context, appearance: appearance)
        cacheEntry = CacheEntry(key: key, createdAt: currentDate, style: style)
        return style
    }

    func reset() {
        cacheEntry = nil
        caretFontSizeResolver.reset()
    }

    private func resolveStyle(
        for context: TextContext,
        appearance: NSAppearance?
    ) -> ResolvedOverlayTextStyle {
        let fallbackFontSize = Self.caretHeightSignal(for: context)
            .map(GhostFontSizeResolver.fontSize(fromReferenceHeight:))
        let fallbackColor = GhostTextColorResolver.color(for: appearance)

        if let attributedStyle = axProbe.attributedStyle(for: context),
           let parsedStyle = OverlayAXTextStyleAttributeParser.style(
            from: attributedStyle.attributedString,
            fallbackFontSize: fallbackFontSize
           ) {
            let font = parsedStyle.font ?? fallbackFont(for: context).font
            let color = parsedStyle.textColor
                .map { GhostTextColorResolver.compatibleGhostColor(from: $0, appearance: appearance) }
                ?? fallbackColor
            return ResolvedOverlayTextStyle(
                font: font,
                textColor: color,
                source: .axAttributedString
            )
        }

        let fallback = fallbackFont(for: context)
        return ResolvedOverlayTextStyle(
            font: fallback.font,
            textColor: fallbackColor,
            source: fallback.source
        )
    }

    private func fallbackFont(for context: TextContext) -> (font: NSFont, source: OverlayTextStyleSource) {
        if Self.caretHeightSignal(for: context) != nil {
            return (caretFontSizeResolver.font(for: context), .caretHeightFallback)
        }

        if let profileFont = OverlayAppStyleProfile.font(for: context.app.bundleID) {
            return (profileFont, .appProfileFallback)
        }

        return (NSFont.systemFont(ofSize: 14), .systemDefault)
    }

    private static func caretHeightSignal(for context: TextContext) -> CGFloat? {
        [
            context.previousGlyphRect,
            context.lineReferenceRect,
            context.nextGlyphRect,
            context.caretRect
        ]
        .compactMap { $0?.height }
        .first { $0.isFinite && $0 > 0 }
    }
}

enum OverlayAppStyleProfile {
    static func font(for bundleID: String) -> NSFont? {
        switch bundleID {
        case "com.apple.TextEdit":
            return NSFont.userFont(ofSize: 14) ?? NSFont.systemFont(ofSize: 14)
        case "com.apple.Notes":
            return NSFont.systemFont(ofSize: 15)
        case "com.apple.mail",
             "com.apple.Safari",
             "com.google.Chrome",
             "com.tinyspeck.slackmacgap":
            return NSFont.systemFont(ofSize: 14)
        default:
            return nil
        }
    }
}

struct GhostFontSizeResolver {
    private var focusedFieldKey: FocusedFieldKey?
    private var minimumReferenceHeight: CGFloat?

    mutating func font(for context: TextContext) -> NSFont {
        .systemFont(ofSize: fontSize(for: context))
    }

    mutating func fontSize(for context: TextContext) -> CGFloat {
        let referenceHeight = InlinePreviewGeometry.referenceHeight(for: context)
        let stabilizedHeight = stabilizedReferenceHeight(
            referenceHeight,
            focusedFieldKey: FocusedFieldKey(context: context)
        )
        return Self.fontSize(fromReferenceHeight: stabilizedHeight)
    }

    mutating func reset() {
        focusedFieldKey = nil
        minimumReferenceHeight = nil
    }

    static func fontSize(fromReferenceHeight referenceHeight: CGFloat) -> CGFloat {
        guard referenceHeight.isFinite, referenceHeight > 0 else {
            return 14
        }
        return max(12, min(18, referenceHeight))
    }

    private mutating func stabilizedReferenceHeight(
        _ referenceHeight: CGFloat,
        focusedFieldKey nextKey: FocusedFieldKey
    ) -> CGFloat {
        guard referenceHeight.isFinite, referenceHeight > 0 else {
            return referenceHeight
        }

        if focusedFieldKey != nextKey {
            focusedFieldKey = nextKey
            minimumReferenceHeight = referenceHeight
            return referenceHeight
        }

        let stabilized = min(referenceHeight, minimumReferenceHeight ?? referenceHeight)
        minimumReferenceHeight = stabilized
        return stabilized
    }

    private struct FocusedFieldKey: Equatable {
        let bundleID: String
        let processID: Int32
        let focusedElementID: String

        init(context: TextContext) {
            bundleID = context.app.bundleID
            processID = context.app.processID
            focusedElementID = context.focusedElementID
        }
    }
}

enum GhostTextColorScheme {
    case light
    case dark

    init(appearance: NSAppearance?) {
        let match = appearance?.bestMatch(from: [.aqua, .darkAqua])
        self = match == .darkAqua ? .dark : .light
    }
}

enum GhostTextColorResolver {
    static let minimumContrastRatio: CGFloat = 3

    @MainActor
    static func color() -> NSColor {
        color(for: NSApp?.effectiveAppearance)
    }

    static func color(for appearance: NSAppearance?) -> NSColor {
        color(for: GhostTextColorScheme(appearance: appearance))
    }

    static func color(for scheme: GhostTextColorScheme) -> NSColor {
        switch scheme {
        case .light:
            return NSColor(srgbRed: 0, green: 0, blue: 0, alpha: 0.52)
        case .dark:
            return NSColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.58)
        }
    }

    static func compatibleGhostColor(from textColor: NSColor, appearance: NSAppearance?) -> NSColor {
        let converted = textColor.usingColorSpace(.sRGB) ?? textColor
        let fallback = color(for: appearance)
        let alpha = max(0.42, min(0.62, fallback.alphaComponent * max(0.7, converted.alphaComponent)))
        return NSColor(
            srgbRed: converted.redComponent,
            green: converted.greenComponent,
            blue: converted.blueComponent,
            alpha: alpha
        )
    }

    static func backgroundColor(for scheme: GhostTextColorScheme) -> NSColor {
        switch scheme {
        case .light:
            return .white
        case .dark:
            return .black
        }
    }

    static func contrastRatio(foreground: NSColor, compositedOver background: NSColor) -> CGFloat {
        let foregroundComponents = components(of: foreground)
        let backgroundComponents = components(of: background)
        let red = foregroundComponents.red * foregroundComponents.alpha
            + backgroundComponents.red * (1 - foregroundComponents.alpha)
        let green = foregroundComponents.green * foregroundComponents.alpha
            + backgroundComponents.green * (1 - foregroundComponents.alpha)
        let blue = foregroundComponents.blue * foregroundComponents.alpha
            + backgroundComponents.blue * (1 - foregroundComponents.alpha)

        let foregroundLuminance = relativeLuminance(red: red, green: green, blue: blue)
        let backgroundLuminance = relativeLuminance(
            red: backgroundComponents.red,
            green: backgroundComponents.green,
            blue: backgroundComponents.blue
        )
        let lighter = max(foregroundLuminance, backgroundLuminance)
        let darker = min(foregroundLuminance, backgroundLuminance)
        return (lighter + 0.05) / (darker + 0.05)
    }

    private static func components(of color: NSColor) -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
        let converted = color.usingColorSpace(.sRGB) ?? color
        return (
            red: converted.redComponent,
            green: converted.greenComponent,
            blue: converted.blueComponent,
            alpha: converted.alphaComponent
        )
    }

    private static func relativeLuminance(red: CGFloat, green: CGFloat, blue: CGFloat) -> CGFloat {
        func channel(_ value: CGFloat) -> CGFloat {
            value <= 0.03928 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * channel(red) + 0.7152 * channel(green) + 0.0722 * channel(blue)
    }
}
