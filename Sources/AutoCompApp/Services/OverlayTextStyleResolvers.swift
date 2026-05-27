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
