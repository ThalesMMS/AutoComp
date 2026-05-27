import AppKit
import AutoCompCore
@testable import AutoCompApp
import XCTest

final class OverlayStyleResolverTests: XCTestCase {
    func testDirectionDetectorUsesRightToLeftScripts() {
        XCTAssertTrue(TextDirectionDetector.isRightToLeft("مرحبا بالعالم"))
        XCTAssertTrue(TextDirectionDetector.isRightToLeft("שלום עולם"))
    }

    func testDirectionDetectorDefaultsWeakTextToLeftToRight() {
        XCTAssertFalse(TextDirectionDetector.isRightToLeft(""))
        XCTAssertFalse(TextDirectionDetector.isRightToLeft("   "))
        XCTAssertFalse(TextDirectionDetector.isRightToLeft("12345"))
    }

    func testDirectionDetectorUsesLastStrongCharacterForMixedText() {
        XCTAssertEqual(TextDirectionDetector.direction(for: "hello مرحبا"), .rightToLeft)
        XCTAssertEqual(TextDirectionDetector.direction(for: "مرحبا hello"), .leftToRight)
        XCTAssertEqual(TextDirectionDetector.direction(for: "مرحبا 123"), .rightToLeft)
    }

    func testGhostTextColorPassesMinimumContrastInLightAndDarkAppearances() {
        for scheme in [GhostTextColorScheme.light, .dark] {
            let color = GhostTextColorResolver.color(for: scheme)
            let background = GhostTextColorResolver.backgroundColor(for: scheme)
            XCTAssertGreaterThanOrEqual(
                GhostTextColorResolver.contrastRatio(foreground: color, compositedOver: background),
                GhostTextColorResolver.minimumContrastRatio
            )
        }
    }

    func testGhostTextColorDiffersBetweenLightAndDarkAppearances() {
        XCTAssertNotEqual(
            GhostTextColorResolver.color(for: .light).usingColorSpace(.sRGB),
            GhostTextColorResolver.color(for: .dark).usingColorSpace(.sRGB)
        )
    }

    func testGhostFontSizeResolverUsesApproximateFieldLineHeightWithSystemFont() {
        var resolver = GhostFontSizeResolver()
        let context = textContext(
            caretRect: CGRect(x: 100, y: 20, width: 2, height: 16),
            previousGlyphRect: CGRect(x: 92, y: 20, width: 8, height: 16)
        )

        let font = resolver.font(for: context)

        XCTAssertEqual(font.pointSize, 16)
        XCTAssertEqual(font.fontName, NSFont.systemFont(ofSize: 16).fontName)
    }

    func testGhostFontSizeResolverStabilizesLargerReadingsWithinField() {
        var resolver = GhostFontSizeResolver()
        let first = resolver.fontSize(for: textContext(
            caretRect: CGRect(x: 100, y: 20, width: 2, height: 12),
            previousGlyphRect: CGRect(x: 92, y: 20, width: 8, height: 12)
        ))
        let second = resolver.fontSize(for: textContext(
            caretRect: CGRect(x: 100, y: 20, width: 2, height: 80),
            previousGlyphRect: CGRect(x: 92, y: 20, width: 8, height: 80)
        ))

        XCTAssertEqual(first, 12)
        XCTAssertEqual(second, 12)
    }

    func testGhostFontSizeResolverResetsWhenFieldChangesOrHides() {
        var resolver = GhostFontSizeResolver()
        _ = resolver.fontSize(for: textContext(
            focusedElementID: "first-field",
            caretRect: CGRect(x: 100, y: 20, width: 2, height: 12),
            previousGlyphRect: CGRect(x: 92, y: 20, width: 8, height: 12)
        ))

        let newFieldSize = resolver.fontSize(for: textContext(
            focusedElementID: "second-field",
            caretRect: CGRect(x: 100, y: 20, width: 2, height: 18),
            previousGlyphRect: CGRect(x: 92, y: 20, width: 8, height: 18)
        ))
        resolver.reset()
        let afterResetSize = resolver.fontSize(for: textContext(
            focusedElementID: "first-field",
            caretRect: CGRect(x: 100, y: 20, width: 2, height: 18),
            previousGlyphRect: CGRect(x: 92, y: 20, width: 8, height: 18)
        ))

        XCTAssertEqual(newFieldSize, 18)
        XCTAssertEqual(afterResetSize, 18)
    }

    private func textContext(
        focusedElementID: String = "field",
        caretRect: CGRect?,
        previousGlyphRect: CGRect? = nil
    ) -> TextContext {
        TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: focusedElementID,
            textBeforeCursor: "Hello",
            selectedRange: NSRange(location: 5, length: 0),
            caretRect: caretRect,
            focusedElementRect: CGRect(x: 80, y: 10, width: 300, height: 40),
            previousGlyphRect: previousGlyphRect,
            caretGeometryQuality: caretRect == nil ? .glyph : .directCaret
        )
    }
}
