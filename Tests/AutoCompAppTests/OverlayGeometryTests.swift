import ApplicationServices
import AppKit
import AutoCompCore
@testable import AutoCompApp
import XCTest

final class OverlayGeometryTests: XCTestCase {
    func testTextGeometryQualityPrefersDirectCaretOverGlyph() {
        let quality = AXTextGeometryResolver.bestQuality(
            caretRect: CGRect(x: 100, y: 20, width: 2, height: 20),
            previousGlyphRect: CGRect(x: 92, y: 20, width: 8, height: 20),
            lineReferenceRect: CGRect(x: 92, y: 20, width: 8, height: 20),
            focusedElementRect: CGRect(x: 80, y: 10, width: 300, height: 40)
        )

        XCTAssertEqual(quality, .directCaret)
    }

    func testTextGeometryQualityFallsBackThroughGlyphLineMetricAndElementFrame() {
        XCTAssertEqual(
            AXTextGeometryResolver.bestQuality(
                caretRect: nil,
                previousGlyphRect: CGRect(x: 92, y: 20, width: 8, height: 20),
                lineReferenceRect: CGRect(x: 80, y: 20, width: 80, height: 20),
                focusedElementRect: CGRect(x: 80, y: 10, width: 300, height: 40)
            ),
            .glyph
        )
        XCTAssertEqual(
            AXTextGeometryResolver.bestQuality(
                caretRect: nil,
                previousGlyphRect: nil,
                lineReferenceRect: CGRect(x: 80, y: 20, width: 80, height: 20),
                focusedElementRect: CGRect(x: 80, y: 10, width: 300, height: 40)
            ),
            .lineMetric
        )
        XCTAssertEqual(
            AXTextGeometryResolver.bestQuality(
                caretRect: nil,
                previousGlyphRect: nil,
                lineReferenceRect: nil,
                focusedElementRect: CGRect(x: 80, y: 10, width: 300, height: 40)
            ),
            .elementFrame
        )
        XCTAssertEqual(
            AXTextGeometryResolver.bestQuality(
                caretRect: nil,
                previousGlyphRect: nil,
                lineReferenceRect: nil,
                focusedElementRect: nil
            ),
            .unavailable
        )
    }

    func testObservedCharacterWidthUsesGlyphMetrics() {
        XCTAssertEqual(
            AXTextGeometryResolver.observedCharacterWidth(
                previousGlyphRect: CGRect(x: 92, y: 20, width: 8, height: 20),
                nextGlyphRect: CGRect(x: 102, y: 20, width: 9, height: 20)
            ),
            8
        )
        XCTAssertEqual(
            AXTextGeometryResolver.observedCharacterWidth(
                previousGlyphRect: nil,
                nextGlyphRect: CGRect(x: 102, y: 20, width: 9, height: 20)
            ),
            9
        )
        XCTAssertNil(
            AXTextGeometryResolver.observedCharacterWidth(
                previousGlyphRect: CGRect(x: 92, y: 20, width: 120, height: 20),
                nextGlyphRect: nil
            )
        )
    }

    func testTextMarkerFallbackEligibilityIsLimitedToBrowsers() {
        XCTAssertTrue(AXTextMarkerGeometryFallback.isEligibleBrowser(bundleID: "com.google.Chrome"))
        XCTAssertTrue(AXTextMarkerGeometryFallback.isEligibleBrowser(bundleID: "com.apple.Safari"))
        XCTAssertFalse(AXTextMarkerGeometryFallback.isEligibleBrowser(bundleID: "com.apple.TextEdit"))
    }

    func testTextMarkerFallbackGateRejectsWhenDisabled() {
        let gate = AXTextMarkerGeometryFallback.gate(
            bundleID: "com.google.Chrome",
            geometry: weakGeometry(),
            isEnabled: false
        )

        XCTAssertEqual(gate, .rejected(reason: "disabled"))
    }

    func testSafeOverlayModeDisablesTextMarkerFallback() {
        XCTAssertTrue(SafeOverlayMode.isEnabled(environment: ["AUTOCOMP_SAFE_OVERLAY_MODE": "1"]))
        XCTAssertTrue(SafeOverlayMode.isEnabled(environment: [:], arguments: ["--safe-overlay-mode"]))
        XCTAssertFalse(
            AXTextMarkerGeometryFallback.isEnabledByDefault(
                environment: ["AUTOCOMP_SAFE_OVERLAY_MODE": "1"],
                arguments: []
            )
        )
        XCTAssertEqual(
            AXTextMarkerGeometryFallback.gate(
                bundleID: "com.google.Chrome",
                geometry: weakGeometry(),
                isEnabled: true,
                isSafeOverlayModeEnabled: true
            ),
            .rejected(reason: "safe-overlay-mode")
        )
    }

    func testTextMarkerFallbackGateRejectsNativeAppsAndStrongGeometry() {
        XCTAssertEqual(
            AXTextMarkerGeometryFallback.gate(
                bundleID: "com.apple.TextEdit",
                geometry: weakGeometry(),
                isEnabled: true
            ),
            .rejected(reason: "ineligible-bundle")
        )
        XCTAssertEqual(
            AXTextMarkerGeometryFallback.gate(
                bundleID: "com.google.Chrome",
                geometry: strongGeometry(),
                isEnabled: true
            ),
            .rejected(reason: "strong-geometry")
        )
    }

    func testTextMarkerFallbackGateAttemptsForOffscreenBrowserCaret() {
        XCTAssertEqual(
            AXTextMarkerGeometryFallback.gate(
                bundleID: "com.apple.Safari",
                geometry: offscreenBrowserGeometry(),
                isEnabled: true
            ),
            .attempt
        )
    }

    func testTextMarkerFallbackGateAttemptsOnlyForWeakBrowserGeometryWhenEnabled() {
        XCTAssertEqual(
            AXTextMarkerGeometryFallback.gate(
                bundleID: "com.google.Chrome",
                geometry: weakGeometry(),
                isEnabled: true
            ),
            .attempt
        )
    }

    func testGoogleDocsSafariOffscreenMetricsUseScreenOCRFallback() {
        let resolver = AXTextGeometryResolver()

        XCTAssertTrue(
            resolver.shouldUseScreenOCRFallback(
                snapshot: googleDocsSnapshot(
                    bundleID: "com.apple.Safari",
                    displayName: "Safari",
                    textBeforeCursor: "Baço de dimensões usuais"
                ),
                geometry: offscreenBrowserGeometry()
            )
        )
    }

    func testGoogleDocsUsableMetricsSkipScreenOCRFallback() {
        let resolver = AXTextGeometryResolver()

        XCTAssertFalse(
            resolver.shouldUseScreenOCRFallback(
                snapshot: googleDocsSnapshot(
                    bundleID: "com.apple.Safari",
                    displayName: "Safari",
                    textBeforeCursor: "Baço de dimensões usuais"
                ),
                geometry: strongGeometry()
            )
        )
    }

    func testCaretPredictionShiftsCaretByAcceptedChunkWidth() {
        let predicted = CaretPrediction.predictedCaretRect(
            acceptedChunk: "next ",
            oldCaretRect: CGRect(x: 100, y: 20, width: 2, height: 20),
            geometryQuality: .directCaret,
            observedCharacterWidth: 8
        )

        XCTAssertEqual(predicted, CGRect(x: 140, y: 20, width: 2, height: 20))
    }

    func testCaretPredictionFallsBackWithoutObservedCharacterWidth() {
        let predicted = CaretPrediction.predictedCaretRect(
            acceptedChunk: "next ",
            oldCaretRect: CGRect(x: 100, y: 20, width: 2, height: 20),
            geometryQuality: .directCaret,
            observedCharacterWidth: nil
        )

        XCTAssertNil(predicted)
    }

    func testCaretPredictionFallsBackForWeakGeometryQuality() {
        let predicted = CaretPrediction.predictedCaretRect(
            acceptedChunk: "next ",
            oldCaretRect: CGRect(x: 100, y: 20, width: 2, height: 20),
            geometryQuality: .elementFrame,
            observedCharacterWidth: 8
        )

        XCTAssertNil(predicted)
    }

    func testPredictedContextUsesAcceptedTextUntilNextAccessibilityRefresh() {
        let context = textContext(
            textBeforeCursor: "Please ",
            selectedRange: NSRange(location: 7, length: 0),
            caretRect: CGRect(x: 100, y: 20, width: 2, height: 20),
            focusedElementRect: CGRect(x: 0, y: 0, width: 500, height: 120),
            previousGlyphRect: CGRect(x: 92, y: 20, width: 8, height: 20)
        )

        let predicted = CaretPrediction.predictedContext(
            afterAccepting: "next ",
            from: context
        )

        XCTAssertEqual(predicted?.textBeforeCursor, "Please next ")
        XCTAssertEqual(predicted?.caretRect, CGRect(x: 140, y: 20, width: 2, height: 20))

        let refreshed = textContext(
            textBeforeCursor: "Please next ",
            selectedRange: NSRange(location: 12, length: 0),
            caretRect: CGRect(x: 141, y: 20, width: 2, height: 20),
            focusedElementRect: CGRect(x: 0, y: 0, width: 500, height: 120),
            previousGlyphRect: CGRect(x: 133, y: 20, width: 8, height: 20)
        )
        XCTAssertEqual(refreshed.caretRect, CGRect(x: 141, y: 20, width: 2, height: 20))
    }

    func testFineCaretAnchorsInlinePreviewImmediatelyAfterCursor() {
        let layout = InlinePreviewGeometry.layout(
            context: textContext(
                selectedRange: NSRange(location: 12, length: 0),
                caretRect: CGRect(x: 100, y: 20, width: 2, height: 20),
                focusedElementRect: CGRect(x: 0, y: 0, width: 500, height: 120)
            ),
            contentSize: NSSize(width: 200, height: 18),
            screenFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        )

        XCTAssertEqual(layout?.origin.x, 103)
        XCTAssertGreaterThan(layout?.origin.y ?? 0, 950)
    }

    func testRightToLeftFineCaretAnchorsInlinePreviewBeforeCursor() {
        let caretRect = CGRect(x: 200, y: 20, width: 2, height: 20)
        let layout = InlinePreviewGeometry.layout(
            context: textContext(
                textBeforeCursor: "שלום עולם",
                selectedRange: NSRange(location: 9, length: 0),
                caretRect: caretRect,
                focusedElementRect: CGRect(x: 0, y: 0, width: 500, height: 120)
            ),
            contentSize: NSSize(width: 120, height: 18),
            screenFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        )

        XCTAssertEqual(layout?.source, .exactAX)
        XCTAssertLessThanOrEqual((layout?.origin.x ?? 0) + (layout?.size.width ?? 0), caretRect.minX - 1)
    }

    func testRightToLeftTextBoxEstimateDoesNotOverlapPreviousText() {
        let focusedRect = CGRect(x: 120, y: 500, width: 520, height: 48)
        let layout = InlinePreviewGeometry.layout(
            context: textContext(
                textBeforeCursor: "مرحبا بالعالم",
                selectedRange: NSRange(location: 13, length: 0),
                caretRect: nil,
                focusedElementRect: focusedRect
            ),
            contentSize: NSSize(width: 160, height: 18),
            screenFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        )

        let convertedFocus = OverlayGeometry.appKitRect(
            accessibilityRect: focusedRect,
            screenFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        )
        XCTAssertEqual(layout?.source, .textBoxEstimate)
        XCTAssertGreaterThanOrEqual(layout?.origin.x ?? 0, convertedFocus.minX)
        XCTAssertLessThan((layout?.origin.x ?? 0) + (layout?.size.width ?? 0), convertedFocus.maxX)
    }

    func testInlineGhostTextLayoutWrapsLongTextInsideVisibleFrame() {
        let layout = InlineGhostTextLayout.resolve(
            text: "This is a long suggestion that should wrap before it leaves the visible screen frame",
            font: NSFont.systemFont(ofSize: 14),
            textDirection: .leftToRight,
            anchorFrame: NSRect(x: 120, y: 500, width: 180, height: 18),
            inputFrame: NSRect(x: 100, y: 460, width: 360, height: 80),
            visibleFrame: NSRect(x: 0, y: 0, width: 420, height: 900),
            observedCharacterWidth: 8,
            geometryQuality: .directCaret,
            maxPanelWidth: 220
        )

        XCTAssertGreaterThan(layout.lines.count, 1)
        XCTAssertLessThanOrEqual(layout.panelFrame.maxX, 420)
        XCTAssertTrue(layout.lines.allSatisfy { $0.width <= layout.panelFrame.width })
    }

    func testInlineGhostTextLayoutExposesKeycapHintPositionWhenSpaceAllows() {
        let layout = InlineGhostTextLayout.resolve(
            text: "continue",
            font: NSFont.systemFont(ofSize: 14),
            textDirection: .leftToRight,
            anchorFrame: NSRect(x: 120, y: 500, width: 180, height: 18),
            inputFrame: NSRect(x: 100, y: 460, width: 360, height: 80),
            visibleFrame: NSRect(x: 0, y: 0, width: 520, height: 900),
            observedCharacterWidth: 8,
            geometryQuality: .directCaret,
            maxPanelWidth: 220
        )

        XCTAssertNotNil(layout.keycapHintFrame)
        XCTAssertGreaterThan(layout.keycapHintFrame?.minX ?? 0, layout.panelFrame.minX)
        XCTAssertLessThanOrEqual(layout.keycapHintFrame?.maxX ?? 0, layout.panelFrame.maxX)
    }

    func testInlineGhostTextLayoutUsesFollowingLineNearRightEdge() {
        let layout = InlineGhostTextLayout.resolve(
            text: "continue here",
            font: NSFont.systemFont(ofSize: 14),
            textDirection: .leftToRight,
            anchorFrame: NSRect(x: 390, y: 500, width: 24, height: 18),
            inputFrame: NSRect(x: 100, y: 460, width: 320, height: 80),
            visibleFrame: NSRect(x: 0, y: 0, width: 420, height: 900),
            observedCharacterWidth: 8,
            geometryQuality: .directCaret,
            maxPanelWidth: 220
        )

        XCTAssertEqual(layout.placementReason, .wrappedLine)
        XCTAssertLessThan(layout.panelFrame.minX, 390)
        XCTAssertLessThan(layout.panelFrame.minY, 500)
    }

    func testInlinePreviewResolutionCanAnchorWrappedGhostLayoutNearRightEdge() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        let resolution = InlinePreviewGeometry.resolve(
            context: textContext(
                selectedRange: NSRange(location: 12, length: 0),
                caretRect: CGRect(x: 990, y: 500, width: 2, height: 20),
                focusedElementRect: CGRect(x: 900, y: 450, width: 100, height: 100),
                caretGeometryQuality: .directCaret
            ),
            contentSize: NSSize(width: 120, height: 18),
            screenFrame: visibleFrame,
            visibleFrame: visibleFrame,
            allowsLineWrapPlacement: true
        )

        guard let anchor = resolution.layout else {
            return XCTFail("Expected an edge anchor for wrapped ghost text placement")
        }
        XCTAssertEqual(anchor.source, InlinePreviewLayoutSource.exactAX)
        XCTAssertGreaterThanOrEqual(anchor.origin.x, 993)
        XCTAssertEqual(anchor.inputFrame, NSRect(x: 900, y: 450, width: 100, height: 100))

        let ghostLayout = InlineGhostTextLayout.resolve(
            text: "continue here",
            font: NSFont.systemFont(ofSize: 14),
            textDirection: .leftToRight,
            anchorFrame: NSRect(origin: anchor.origin, size: anchor.size),
            inputFrame: anchor.inputFrame,
            visibleFrame: visibleFrame,
            observedCharacterWidth: 8,
            geometryQuality: .directCaret,
            maxPanelWidth: 220
        )
        XCTAssertEqual(ghostLayout.placementReason, InlineGhostTextLayout.PlacementReason.wrappedLine)
        XCTAssertLessThan(ghostLayout.panelFrame.minY, anchor.origin.y)
        XCTAssertGreaterThanOrEqual(ghostLayout.panelFrame.minX, visibleFrame.minX)
        XCTAssertLessThanOrEqual(ghostLayout.panelFrame.maxX, visibleFrame.maxX)
    }

    func testInlineGhostTextLayoutKeepsSecondaryScreenFrame() {
        let visibleFrame = NSRect(x: 1_000, y: 0, width: 800, height: 900)
        let layout = InlineGhostTextLayout.resolve(
            text: "secondary display text",
            font: NSFont.systemFont(ofSize: 14),
            textDirection: .leftToRight,
            anchorFrame: NSRect(x: 1_220, y: 500, width: 180, height: 18),
            inputFrame: NSRect(x: 1_100, y: 460, width: 460, height: 80),
            visibleFrame: visibleFrame,
            observedCharacterWidth: 8,
            geometryQuality: .directCaret
        )

        XCTAssertGreaterThanOrEqual(layout.panelFrame.minX, visibleFrame.minX)
        XCTAssertLessThanOrEqual(layout.panelFrame.maxX, visibleFrame.maxX)
    }

    func testInlineGhostTextLayoutPositionsRightToLeftTextBeforeCaret() {
        let anchor = NSRect(x: 300, y: 500, width: 120, height: 18)
        let layout = InlineGhostTextLayout.resolve(
            text: "שלום עולם חדש",
            font: NSFont.systemFont(ofSize: 14),
            textDirection: .rightToLeft,
            anchorFrame: anchor,
            inputFrame: NSRect(x: 100, y: 460, width: 360, height: 80),
            visibleFrame: NSRect(x: 0, y: 0, width: 500, height: 900),
            observedCharacterWidth: 8,
            geometryQuality: .directCaret,
            maxPanelWidth: 220
        )

        XCTAssertEqual(layout.placementReason, .rightToLeft)
        XCTAssertLessThanOrEqual(layout.panelFrame.maxX, anchor.maxX)
        XCTAssertTrue(layout.lines.allSatisfy { $0.indent >= 0 })
    }

    func testSimpleCaretPopupLayoutClampsToVisibleFrame() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 420, height: 320)
        let layout = SimpleCaretPopupLayout.resolve(
            text: "fallback suggestion",
            context: textContext(
                selectedRange: NSRange(location: 12, length: 0),
                caretRect: CGRect(x: 410, y: 300, width: 2, height: 20),
                focusedElementRect: CGRect(x: 300, y: 260, width: 120, height: 50)
            ),
            font: NSFont.systemFont(ofSize: 14),
            screenFrame: visibleFrame,
            visibleFrame: visibleFrame
        )

        XCTAssertNotNil(layout)
        XCTAssertEqual(layout?.placementReason, .clampedToVisibleFrame)
        XCTAssertGreaterThanOrEqual(layout?.panelFrame.minX ?? -1, visibleFrame.minX)
        XCTAssertLessThanOrEqual(layout?.panelFrame.maxX ?? .greatestFiniteMagnitude, visibleFrame.maxX)
        XCTAssertGreaterThanOrEqual(layout?.panelFrame.minY ?? -1, visibleFrame.minY)
        XCTAssertLessThanOrEqual(layout?.panelFrame.maxY ?? .greatestFiniteMagnitude, visibleFrame.maxY)
    }

    func testSimpleCaretPopupLayoutRejectsSelection() {
        let layout = SimpleCaretPopupLayout.resolve(
            text: "fallback suggestion",
            context: textContext(
                selectedRange: NSRange(location: 12, length: 2),
                caretRect: CGRect(x: 120, y: 200, width: 2, height: 20),
                focusedElementRect: CGRect(x: 100, y: 160, width: 240, height: 60)
            ),
            font: NSFont.systemFont(ofSize: 14),
            screenFrame: CGRect(x: 0, y: 0, width: 420, height: 320),
            visibleFrame: CGRect(x: 0, y: 0, width: 420, height: 320)
        )

        XCTAssertNil(layout)
    }

    func testSimpleCaretPopupLayoutCanUseFocusedElementAnchor() {
        let focusedFrame = CGRect(x: 120, y: 180, width: 240, height: 60)
        let layout = SimpleCaretPopupLayout.resolve(
            text: "fallback suggestion",
            context: textContext(
                selectedRange: NSRange(location: 12, length: 0),
                caretRect: nil,
                focusedElementRect: focusedFrame
            ),
            font: NSFont.systemFont(ofSize: 14),
            screenFrame: CGRect(x: 0, y: 0, width: 500, height: 500),
            visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 500)
        )

        XCTAssertEqual(layout?.placementReason, .focusedElement)
        XCTAssertEqual(layout?.anchorFrame, CGRect(x: 120, y: 260, width: 240, height: 60))
    }

    func testMultiSuggestionPopupLayoutClampsToVisibleFrame() {
        let visibleFrame = CGRect(x: 0, y: 0, width: 420, height: 320)
        let layout = MultiSuggestionPopupLayout.resolve(
            suggestion: multiSuggestion(),
            context: textContext(
                selectedRange: NSRange(location: 12, length: 0),
                caretRect: CGRect(x: 410, y: 300, width: 2, height: 20),
                focusedElementRect: CGRect(x: 300, y: 260, width: 120, height: 50)
            ),
            font: NSFont.systemFont(ofSize: 14),
            screenFrame: visibleFrame,
            visibleFrame: visibleFrame
        )

        XCTAssertNotNil(layout)
        XCTAssertEqual(layout?.placementReason, .clampedToVisibleFrame)
        XCTAssertGreaterThanOrEqual(layout?.panelFrame.minX ?? -1, visibleFrame.minX)
        XCTAssertLessThanOrEqual(layout?.panelFrame.maxX ?? .greatestFiniteMagnitude, visibleFrame.maxX)
        XCTAssertGreaterThanOrEqual(layout?.panelFrame.minY ?? -1, visibleFrame.minY)
        XCTAssertLessThanOrEqual(layout?.panelFrame.maxY ?? .greatestFiniteMagnitude, visibleFrame.maxY)
    }

    func testMultiSuggestionPopupLayoutRejectsSelection() {
        let layout = MultiSuggestionPopupLayout.resolve(
            suggestion: multiSuggestion(),
            context: textContext(
                selectedRange: NSRange(location: 12, length: 2),
                caretRect: CGRect(x: 120, y: 200, width: 2, height: 20),
                focusedElementRect: CGRect(x: 100, y: 160, width: 240, height: 60)
            ),
            font: NSFont.systemFont(ofSize: 14),
            screenFrame: CGRect(x: 0, y: 0, width: 420, height: 320),
            visibleFrame: CGRect(x: 0, y: 0, width: 420, height: 320)
        )

        XCTAssertNil(layout)
    }

    func testMultiSuggestionPopupLayoutCanUseFocusedElementAnchor() {
        let focusedFrame = CGRect(x: 120, y: 180, width: 240, height: 60)
        let layout = MultiSuggestionPopupLayout.resolve(
            suggestion: multiSuggestion(),
            context: textContext(
                selectedRange: NSRange(location: 12, length: 0),
                caretRect: nil,
                focusedElementRect: focusedFrame
            ),
            font: NSFont.systemFont(ofSize: 14),
            screenFrame: CGRect(x: 0, y: 0, width: 500, height: 500),
            visibleFrame: CGRect(x: 0, y: 0, width: 500, height: 500)
        )

        XCTAssertEqual(layout?.placementReason, .focusedElement)
        XCTAssertEqual(layout?.anchorFrame, CGRect(x: 120, y: 260, width: 240, height: 60))
    }

    func testCollapsedGoogleDocsCaretStillAnchorsInlinePreview() {
        let layout = InlinePreviewGeometry.layout(
            context: textContext(
                app: AppIdentity(bundleID: "com.google.Chrome", displayName: "Google Chrome", processID: 42),
                textBeforeCursor: "Vamos validar se teste novo agora ",
                selectedRange: NSRange(location: 36, length: 0),
                caretRect: CGRect(x: 768, y: 378, width: 0, height: 17),
                focusedElementRect: CGRect(x: 768, y: 378, width: 625, height: 2)
            ),
            contentSize: NSSize(width: 180, height: 18),
            screenFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        )

        XCTAssertEqual(layout?.source, .exactAX)
        XCTAssertEqual(layout?.origin.x, 770)
        XCTAssertEqual(layout?.origin.y, 604)
    }

    func testWideAccessibilityCaretUsesPreviousGlyphInsertionPoint() {
        let layout = InlinePreviewGeometry.layout(
            context: textContext(
                selectedRange: NSRange(location: 12, length: 0),
                caretRect: CGRect(x: 420, y: 500, width: 120, height: 24),
                focusedElementRect: CGRect(x: 300, y: 460, width: 300, height: 100),
                previousGlyphRect: CGRect(x: 408, y: 500, width: 11, height: 24)
            ),
            contentSize: NSSize(width: 240, height: 20),
            screenFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        )

        XCTAssertEqual(layout?.origin.x, 422)
    }

    func testWideAccessibilityCaretCanUseLeadingInsertionPointAsLastFallback() {
        let layout = InlinePreviewGeometry.layout(
            context: textContext(
                selectedRange: NSRange(location: 12, length: 0),
                caretRect: CGRect(x: 420, y: 500, width: 120, height: 24),
                focusedElementRect: CGRect(x: 300, y: 460, width: 300, height: 100)
            ),
            contentSize: NSSize(width: 240, height: 20),
            screenFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        )

        XCTAssertEqual(layout?.origin.x, 422)
    }

    func testOverlayGeometryValidatorNormalizesWideCollapsedCaret() {
        let validation = overlayValidation(
            for: textContext(
                selectedRange: NSRange(location: 12, length: 0),
                caretRect: CGRect(x: 420, y: 500, width: 120, height: 24),
                focusedElementRect: CGRect(x: 300, y: 460, width: 300, height: 100)
            )
        )

        XCTAssertEqual(validation.caretRect, CGRect(x: 420, y: 476, width: 1, height: 24))
    }

    func testOverlayGeometryValidatorRejectsCaretOutsideAllScreens() {
        let validation = overlayValidation(
            for: textContext(
                selectedRange: NSRange(location: 12, length: 0),
                caretRect: CGRect(x: 5_000, y: 5_000, width: 2, height: 20),
                focusedElementRect: nil
            )
        )

        XCTAssertNil(validation.caretRect)
    }

    func testOverlayGeometryValidatorRejectsCaretFarFromFocusedElement() {
        let validation = overlayValidation(
            for: textContext(
                selectedRange: NSRange(location: 12, length: 0),
                caretRect: CGRect(x: 900, y: 900, width: 2, height: 20),
                focusedElementRect: CGRect(x: 100, y: 100, width: 300, height: 80)
            )
        )

        XCTAssertNotNil(validation.focusedElementRect)
        XCTAssertNil(validation.caretRect)
    }

    func testOverlayGeometryValidatorNormalizesRetinaPhysicalCoordinates() {
        let validation = overlayValidation(
            for: textContext(
                selectedRange: NSRange(location: 12, length: 0),
                caretRect: CGRect(x: 1_600, y: 960, width: 4, height: 36),
                focusedElementRect: nil
            )
        )

        XCTAssertEqual(validation.caretRect, CGRect(x: 800, y: 502, width: 2, height: 18))
    }

    func testOverlayGeometryValidatorAcceptsSecondaryScreenRect() {
        let validation = overlayValidation(
            for: textContext(
                selectedRange: NSRange(location: 12, length: 0),
                caretRect: CGRect(x: 1_220, y: 500, width: 2, height: 20),
                focusedElementRect: nil
            ),
            screenFrames: [
                CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
                CGRect(x: 1_000, y: 0, width: 1_000, height: 1_000)
            ]
        )

        XCTAssertEqual(validation.caretRect, CGRect(x: 1_220, y: 480, width: 2, height: 20))
    }

    func testOverlayGeometryValidatorAppliesCaretQualityCaps() {
        let weakValidation = overlayValidation(
            for: textContext(
                selectedRange: NSRange(location: 12, length: 0),
                caretRect: CGRect(x: 300, y: 500, width: 2, height: 150),
                focusedElementRect: nil,
                caretGeometryQuality: .elementFrame
            )
        )
        let directValidation = overlayValidation(
            for: textContext(
                selectedRange: NSRange(location: 12, length: 0),
                caretRect: CGRect(x: 300, y: 500, width: 2, height: 150),
                focusedElementRect: nil,
                caretGeometryQuality: .directCaret
            )
        )

        XCTAssertNil(weakValidation.caretRect)
        XCTAssertEqual(directValidation.caretRect, CGRect(x: 300, y: 350, width: 2, height: 150))
    }

    func testOverlayGeometryValidatorRejectsFocusedFrameOutsideScreen() {
        let validation = overlayValidation(
            for: textContext(
                selectedRange: NSRange(location: 12, length: 0),
                caretRect: nil,
                focusedElementRect: CGRect(x: 4_000, y: 4_000, width: 300, height: 80)
            )
        )

        XCTAssertNil(validation.focusedElementRect)
    }

    func testInlinePreviewDoesNotFlipLeftWhenRightEdgeHasNoUsefulSpace() {
        let layout = InlinePreviewGeometry.layout(
            context: textContext(
                selectedRange: NSRange(location: 12, length: 0),
                caretRect: CGRect(x: 990, y: 500, width: 2, height: 20),
                focusedElementRect: CGRect(x: 900, y: 450, width: 100, height: 100)
            ),
            contentSize: NSSize(width: 120, height: 18),
            screenFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        )

        XCTAssertNil(layout)
    }

    func testNonCollapsedSelectionCannotUseInlineVisualPreview() {
        let layout = InlinePreviewGeometry.layout(
            context: textContext(
                selectedRange: NSRange(location: 12, length: 3),
                caretRect: CGRect(x: 100, y: 500, width: 2, height: 20),
                focusedElementRect: CGRect(x: 0, y: 450, width: 500, height: 100)
            ),
            contentSize: NSSize(width: 120, height: 18),
            screenFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        )

        XCTAssertNil(layout)
    }

    func testPreviousCharacterRectImprovesLineReference() {
        let context = textContext(
            selectedRange: NSRange(location: 12, length: 0),
            caretRect: CGRect(x: 100, y: 200, width: 2, height: 8),
            focusedElementRect: CGRect(x: 0, y: 150, width: 500, height: 100),
            previousGlyphRect: CGRect(x: 82, y: 190, width: 16, height: 24)
        )
        let layout = InlinePreviewGeometry.layout(
            context: context,
            contentSize: NSSize(width: 120, height: 20),
            screenFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        )

        XCTAssertEqual(InlinePreviewGeometry.referenceHeight(for: context), 24)
        XCTAssertEqual(layout?.origin.y, 786)
    }

    func testFocusedElementFallbackEstimatesInlinePositionInsideTextBox() {
        let focusedRect = CGRect(x: 120, y: 500, width: 520, height: 48)
        let layout = InlinePreviewGeometry.layout(
            context: textContext(
                textBeforeCursor: "Vamos tentar",
                selectedRange: NSRange(location: 13, length: 0),
                caretRect: nil,
                focusedElementRect: focusedRect
            ),
            contentSize: NSSize(width: 160, height: 18),
            screenFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        )

        let convertedFocus = OverlayGeometry.appKitRect(
            accessibilityRect: focusedRect,
            screenFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        )
        XCTAssertEqual(layout?.source, .textBoxEstimate)
        XCTAssertGreaterThan(layout?.origin.x ?? 0, convertedFocus.minX + 8)
        XCTAssertLessThan(layout?.origin.x ?? CGFloat.greatestFiniteMagnitude, convertedFocus.maxX)
        XCTAssertTrue(convertedFocus.insetBy(dx: -1, dy: -1).contains(CGPoint(x: layout?.origin.x ?? 0, y: layout?.origin.y ?? 0)))
    }

    func testWebLikeFineCaretWithoutGlyphUsesExactCaret() {
        let focusedRect = CGRect(x: 100, y: 700, width: 520, height: 72)
        let layout = InlinePreviewGeometry.layout(
            context: textContext(
                app: AppIdentity(bundleID: "com.openai.codex", displayName: "Codex", processID: 42),
                textBeforeCursor: "Vamos tentar ver se",
                selectedRange: NSRange(location: 19, length: 0),
                caretRect: CGRect(x: 390, y: 735, width: 2, height: 20),
                focusedElementRect: focusedRect,
                previousGlyphRect: nil
            ),
            contentSize: NSSize(width: 180, height: 18),
            screenFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        )

        XCTAssertEqual(layout?.source, .exactAX)
        XCTAssertEqual(layout?.origin.x, 393)
        XCTAssertEqual(layout?.origin.y, 245)
    }

    func testWebLikeSuspiciousCaretWithoutGlyphUsesTextBoxEstimate() {
        let focusedRect = CGRect(x: 100, y: 700, width: 520, height: 72)
        let layout = InlinePreviewGeometry.layout(
            context: textContext(
                app: AppIdentity(bundleID: "com.openai.codex", displayName: "Codex", processID: 42),
                textBeforeCursor: "Vamos tentar ver se",
                selectedRange: NSRange(location: 19, length: 0),
                caretRect: CGRect(x: 0, y: 1008, width: 0, height: 0),
                focusedElementRect: focusedRect,
                previousGlyphRect: nil
            ),
            contentSize: NSSize(width: 180, height: 18),
            screenFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        )

        let convertedFocus = OverlayGeometry.appKitRect(
            accessibilityRect: focusedRect,
            screenFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        )
        XCTAssertEqual(layout?.source, .textBoxEstimate)
        XCTAssertGreaterThan(layout?.origin.x ?? 0, convertedFocus.minX)
        XCTAssertLessThan(layout?.origin.x ?? CGFloat.greatestFiniteMagnitude, 300)
        XCTAssertGreaterThan(layout?.origin.y ?? 0, convertedFocus.minY)
        XCTAssertLessThan((layout?.origin.y ?? 0) + (layout?.size.height ?? 0), convertedFocus.maxY)
    }

    func testWebLikeLongTextEstimateUsesLastWrappedLineInsteadOfRightEdgeClamp() {
        let focusedRect = CGRect(x: 278, y: 829, width: 712, height: 88)
        let text = """
        Explique rapidamente o problema principal que estamos investigando agora e depois conclua com uma frase curta
        """
        let layout = InlinePreviewGeometry.layout(
            context: textContext(
                app: AppIdentity(bundleID: "com.openai.codex", displayName: "Codex", processID: 42),
                textBeforeCursor: text,
                selectedRange: NSRange(location: (text as NSString).length, length: 0),
                caretRect: CGRect(x: 0, y: 1008, width: 0, height: 0),
                focusedElementRect: focusedRect,
                previousGlyphRect: nil
            ),
            contentSize: NSSize(width: 180, height: 18),
            screenFrame: CGRect(x: 0, y: 0, width: 1_200, height: 1_000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_200, height: 1_000)
        )

        let convertedFocus = OverlayGeometry.appKitRect(
            accessibilityRect: focusedRect,
            screenFrame: CGRect(x: 0, y: 0, width: 1_200, height: 1_000)
        )
        XCTAssertEqual(layout?.source, .textBoxEstimate)
        XCTAssertLessThan(layout?.origin.x ?? CGFloat.greatestFiniteMagnitude, convertedFocus.maxX - 120)
        XCTAssertGreaterThan(layout?.origin.y ?? 0, convertedFocus.minY)
    }

    func testZeroOriginFocusedElementFallbackIsRejected() {
        let layout = InlinePreviewGeometry.layout(
            context: textContext(
                selectedRange: NSRange(location: 12, length: 0),
                caretRect: nil,
                focusedElementRect: CGRect(x: 0, y: 0, width: 500, height: 120)
            ),
            contentSize: NSSize(width: 120, height: 18),
            screenFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        )

        XCTAssertNil(layout)
    }

    func testZeroOriginMetricRectIsRejected() {
        let layout = InlinePreviewGeometry.layout(
            context: textContext(
                selectedRange: NSRange(location: 12, length: 0),
                caretRect: CGRect(x: 0, y: 0, width: 2, height: 20),
                focusedElementRect: CGRect(x: 0, y: 0, width: 500, height: 100),
                previousGlyphRect: nil
            ),
            contentSize: NSSize(width: 120, height: 18),
            screenFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        )

        XCTAssertNil(layout)
    }

    func testAccessibilityRectConvertsFromTopLeftToAppKitCoordinates() {
        let rect = OverlayGeometry.appKitRect(
            accessibilityRect: CGRect(x: 10, y: 20, width: 30, height: 40),
            screenFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
        )

        XCTAssertEqual(rect, CGRect(x: 10, y: 940, width: 30, height: 40))
    }

    private func textContext(
        app: AppIdentity = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
        textBeforeCursor: String = "Hello world",
        selectedRange: NSRange?,
        caretRect: CGRect?,
        focusedElementRect: CGRect? = nil,
        previousGlyphRect: CGRect? = nil,
        nextGlyphRect: CGRect? = nil,
        lineReferenceRect: CGRect? = nil,
        caretGeometryQuality: CaretGeometryQuality = .directCaret
    ) -> TextContext {
        TextContext(
            app: app,
            focusedElementID: "field",
            textBeforeCursor: textBeforeCursor,
            selectedRange: selectedRange,
            caretRect: caretRect,
            focusedElementRect: focusedElementRect,
            previousGlyphRect: previousGlyphRect,
            nextGlyphRect: nextGlyphRect,
            lineReferenceRect: lineReferenceRect,
            caretGeometryQuality: caretGeometryQuality
        )
    }

    private func overlayValidation(
        for context: TextContext,
        screenFrames: [CGRect] = [CGRect(x: 0, y: 0, width: 1_000, height: 1_000)]
    ) -> OverlayGeometryValidation {
        OverlayGeometryValidator(
            screenFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
            screenFrames: screenFrames
        ).validate(context: context)
    }

    private func multiSuggestion() -> Suggestion {
        Suggestion(
            baseContextID: UUID(),
            visibleText: " first",
            alternatives: [
                SuggestionAlternative(visibleText: " first"),
                SuggestionAlternative(visibleText: " second longer"),
                SuggestionAlternative(visibleText: " third")
            ],
            latencyMs: 12
        )
    }

    private func weakGeometry() -> AXTextGeometrySnapshot {
        AXTextGeometrySnapshot(
            focusedElementRect: CGRect(x: 80, y: 10, width: 300, height: 40),
            caretRect: nil,
            previousGlyphRect: nil,
            nextGlyphRect: nil,
            lineReferenceRect: nil,
            caretGeometryQuality: .elementFrame,
            observedCharacterWidth: nil
        )
    }

    private func strongGeometry() -> AXTextGeometrySnapshot {
        AXTextGeometrySnapshot(
            focusedElementRect: CGRect(x: 80, y: 10, width: 300, height: 40),
            caretRect: CGRect(x: 100, y: 20, width: 2, height: 20),
            previousGlyphRect: CGRect(x: 92, y: 20, width: 8, height: 20),
            nextGlyphRect: nil,
            lineReferenceRect: CGRect(x: 92, y: 20, width: 8, height: 20),
            caretGeometryQuality: .directCaret,
            observedCharacterWidth: 8
        )
    }

    private func offscreenBrowserGeometry() -> AXTextGeometrySnapshot {
        AXTextGeometrySnapshot(
            focusedElementRect: CGRect(x: 0, y: -9847, width: 3000, height: 444),
            caretRect: CGRect(x: 57, y: -9709, width: 2, height: 15),
            previousGlyphRect: CGRect(x: 53, y: -9709, width: 6, height: 15),
            nextGlyphRect: CGRect(x: 0, y: -9694, width: 2, height: 15),
            lineReferenceRect: CGRect(x: 53, y: -9709, width: 6, height: 15),
            caretGeometryQuality: .directCaret,
            observedCharacterWidth: 6
        )
    }

    private func googleDocsSnapshot(
        bundleID: String,
        displayName: String,
        textBeforeCursor: String
    ) -> AXFocusSnapshot {
        AXFocusSnapshot(
            app: AppIdentity(bundleID: bundleID, displayName: displayName, processID: 1),
            bundleID: bundleID,
            displayName: displayName,
            focusedElement: AXUIElementCreateSystemWide(),
            focusedElementID: "docs-field",
            domain: "docs.google.com",
            domainResolution: .known("docs.google.com"),
            role: "AXTextArea",
            subrole: nil,
            isGoogleDocsElement: true,
            isCodexComposerElement: false,
            selectedRange: NSRange(location: (textBeforeCursor as NSString).length, length: 0),
            fullText: textBeforeCursor,
            textLength: (textBeforeCursor as NSString).length,
            textBeforeCursor: textBeforeCursor,
            textAfterCursor: nil,
            selectedText: nil,
            fullTextWindow: textBeforeCursor
        )
    }
}
