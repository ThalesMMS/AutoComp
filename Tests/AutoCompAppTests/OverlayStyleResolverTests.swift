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

    func testAXFontDictionaryParserResolvesFontNameAndSize() {
        let font = OverlayAXTextStyleAttributeParser.font(
            fromAXFontValue: [
                "AXFontName": "Menlo-Regular",
                "AXFontSize": 13
            ],
            fallbackSize: 16
        )

        XCTAssertEqual(font?.pointSize, 13)
        XCTAssertTrue(font?.fontName.localizedCaseInsensitiveContains("Menlo") == true)
    }

    func testAXColorParserAcceptsNSColorAndCGColor() {
        let nsColor = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 0.8)
        XCTAssertEqual(colorComponents(OverlayAXTextStyleAttributeParser.color(fromAXColorValue: nsColor)), [0.2, 0.4, 0.6, 0.8])

        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let cgColor = CGColor(colorSpace: colorSpace, components: [0.7, 0.1, 0.3, 0.9])!
        XCTAssertEqual(colorComponents(OverlayAXTextStyleAttributeParser.color(fromAXColorValue: cgColor)), [0.7, 0.1, 0.3, 0.9])
    }

    func testProbeRangeUsesAdjacentCharacterAtBeginningAndCollapsedCaret() {
        let beginning = OverlayStyleProbeRangeResolver.probeRange(
            selectedRange: NSRange(location: 0, length: 0),
            textLength: 5
        )
        let collapsed = OverlayStyleProbeRangeResolver.probeRange(
            selectedRange: NSRange(location: 4, length: 0),
            textLength: 5
        )

        XCTAssertEqual(beginning?.location, 0)
        XCTAssertEqual(beginning?.length, 1)
        XCTAssertEqual(collapsed?.location, 3)
        XCTAssertEqual(collapsed?.length, 1)
    }

    func testProbeRangeUsesFirstSelectedCharacterForActiveSelection() {
        let range = OverlayStyleProbeRangeResolver.probeRange(
            selectedRange: NSRange(location: 2, length: 3),
            textLength: 8
        )

        XCTAssertEqual(range?.location, 2)
        XCTAssertEqual(range?.length, 1)
    }

    func testOverlayStyleResolverUsesAXAttributedStringAndCachesBriefly() {
        let probe = FakeOverlayTextStyleProbe(result: OverlayAXTextStyleProbeResult(
            attributedString: NSAttributedString(
                string: "x",
                attributes: [
                    .font: NSFont(name: "Menlo-Regular", size: 13) ?? NSFont.monospacedSystemFont(ofSize: 13, weight: .regular),
                    .foregroundColor: NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)
                ]
            ),
            range: NSRange(location: 4, length: 1)
        ))
        let resolver = OverlayTextStyleResolver(axProbe: probe, cacheTTL: 1, now: { Date(timeIntervalSince1970: 10) })
        let context = textContext(caretRect: CGRect(x: 100, y: 20, width: 2, height: 16))

        let first = resolver.style(for: context)
        let second = resolver.style(for: context)

        XCTAssertEqual(probe.callCount, 1)
        XCTAssertEqual(first.source, .axAttributedString)
        XCTAssertEqual(second.source, .axAttributedString)
        XCTAssertEqual(first.font.pointSize, 13)
        XCTAssertEqual(Array(colorComponents(first.textColor).prefix(3)), [0.2, 0.4, 0.6])
    }

    func testOverlayStyleResolverFallsBackToCaretHeightWhenAttributedStringIsMissing() {
        let probe = FakeOverlayTextStyleProbe(result: nil)
        let resolver = OverlayTextStyleResolver(axProbe: probe)
        let context = textContext(caretRect: CGRect(x: 100, y: 20, width: 2, height: 17))

        let style = resolver.style(for: context)

        XCTAssertEqual(style.source, .caretHeightFallback)
        XCTAssertEqual(style.font.pointSize, 17)
    }

    func testOverlayStyleResolverNegativeProbeIsCachedAcrossCaretMovementInSameField() {
        let probe = FakeOverlayTextStyleProbe(result: nil)
        let resolver = OverlayTextStyleResolver(axProbe: probe, cacheTTL: 1)
        let first = textContext(
            caretRect: CGRect(x: 100, y: 20, width: 2, height: 17),
            selectedLocation: 5
        )
        let moved = textContext(
            caretRect: CGRect(x: 108, y: 20, width: 2, height: 17),
            selectedLocation: 6
        )

        _ = resolver.style(for: first)
        _ = resolver.style(for: moved)

        XCTAssertEqual(probe.callCount, 1)
    }

    func testOverlayStyleResolverFallsBackToSystemDefaultForUnknownAppWithoutGeometry() {
        let probe = FakeOverlayTextStyleProbe(result: nil)
        let resolver = OverlayTextStyleResolver(axProbe: probe)
        let context = textContext(
            app: AppIdentity(bundleID: "dev.example.Unknown", displayName: "Unknown", processID: 1),
            caretRect: nil,
            previousGlyphRect: nil
        )

        let style = resolver.style(for: context)

        XCTAssertEqual(style.source, .systemDefault)
        XCTAssertEqual(style.font.pointSize, 14)
    }

    func testOverlayStyleResolverUsesAppProfileFallbackWhenKnownAppHasNoGeometry() {
        let probe = FakeOverlayTextStyleProbe(result: nil)
        let resolver = OverlayTextStyleResolver(axProbe: probe)
        let context = textContext(
            app: AppIdentity(bundleID: "com.apple.Notes", displayName: "Notes", processID: 1),
            caretRect: nil,
            previousGlyphRect: nil
        )

        let style = resolver.style(for: context)

        XCTAssertEqual(style.source, .appProfileFallback)
        XCTAssertEqual(style.font.pointSize, 15)
    }

    private func textContext(
        app: AppIdentity = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
        focusedElementID: String = "field",
        caretRect: CGRect?,
        previousGlyphRect: CGRect? = nil,
        selectedLocation: Int = 5
    ) -> TextContext {
        TextContext(
            app: app,
            focusedElementID: focusedElementID,
            textBeforeCursor: "Hello",
            selectedRange: NSRange(location: selectedLocation, length: 0),
            caretRect: caretRect,
            focusedElementRect: CGRect(x: 80, y: 10, width: 300, height: 40),
            previousGlyphRect: previousGlyphRect,
            caretGeometryQuality: caretRect == nil ? .glyph : .directCaret
        )
    }

    private func colorComponents(_ color: NSColor?) -> [CGFloat] {
        guard let color = color?.usingColorSpace(.sRGB) else {
            return []
        }
        return [
            rounded(color.redComponent),
            rounded(color.greenComponent),
            rounded(color.blueComponent),
            rounded(color.alphaComponent)
        ]
    }

    private func rounded(_ value: CGFloat) -> CGFloat {
        (value * 100).rounded() / 100
    }
}

private final class FakeOverlayTextStyleProbe: OverlayTextStyleProbing {
    private let result: OverlayAXTextStyleProbeResult?
    private(set) var callCount = 0

    init(result: OverlayAXTextStyleProbeResult?) {
        self.result = result
    }

    func attributedStyle(for context: TextContext) -> OverlayAXTextStyleProbeResult? {
        callCount += 1
        return result
    }
}
