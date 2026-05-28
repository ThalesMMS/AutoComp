import AppKit
import AutoCompCore

enum OverlayGeometryAppClass: String, CaseIterable, Equatable {
    case nativeEditor = "native-editor"
    case browserEditor = "browser-editor"
    case multiMonitorEditor = "multi-monitor-editor"
    case ocrRecoveredEditor = "ocr-recovered-editor"
}

struct OverlayGeometryInputRects: Equatable {
    let caretRect: CGRect?
    let focusedElementRect: CGRect?
    let previousGlyphRect: CGRect?
    let nextGlyphRect: CGRect?
    let lineReferenceRect: CGRect?
}

struct OverlayGeometryValidationExpectation: Equatable {
    let focusedElementRect: CGRect?
    let caretRect: CGRect?
    let previousGlyphRect: CGRect?
    let nextGlyphRect: CGRect?
    let lineReferenceRect: CGRect?
}

struct OverlayGeometryCorpusExpectation: Equatable {
    let tier: PreviewPresentationTier
    let reason: String
    let validation: OverlayGeometryValidationExpectation
    let inlineSource: InlinePreviewLayoutSource?
    let inlineRejectionReason: String?
}

struct OverlayGeometryCorpusFixture: Equatable, Identifiable {
    let id: String
    let scenario: String
    let appClass: OverlayGeometryAppClass
    let app: AppIdentity
    let inputRects: OverlayGeometryInputRects
    let selectedRange: NSRange?
    let textBeforeCursor: String
    let caretGeometryQuality: CaretGeometryQuality
    let observedCharacterWidth: CGFloat?
    let captureSources: Set<TextCaptureSource>
    let screenFrame: CGRect
    let visibleFrame: CGRect
    let screenFrames: [CGRect]
    let contentSize: NSSize
    let expected: OverlayGeometryCorpusExpectation

    func makeContext() -> TextContext {
        TextContext(
            app: app,
            focusedElementID: "corpus-\(id)",
            textBeforeCursor: textBeforeCursor,
            selectedRange: selectedRange,
            caretRect: inputRects.caretRect,
            focusedElementRect: inputRects.focusedElementRect,
            previousGlyphRect: inputRects.previousGlyphRect,
            nextGlyphRect: inputRects.nextGlyphRect,
            lineReferenceRect: inputRects.lineReferenceRect,
            caretGeometryQuality: caretGeometryQuality,
            observedCharacterWidth: observedCharacterWidth,
            captureSources: captureSources
        )
    }
}

struct OverlayGeometryCorpusResult: Equatable {
    let fixtureID: String
    let scenario: String
    let appClass: OverlayGeometryAppClass
    let tier: PreviewPresentationTier
    let reason: String
    let validation: OverlayGeometryValidation
    let inlineSource: InlinePreviewLayoutSource?
    let inlineRejectionReason: String?

    var redactedLogLine: String {
        let inline = inlineSource?.rawValue ?? "rejected"
        let rejection = inlineRejectionReason ?? "none"
        return "overlay-geometry-corpus fixture=\(fixtureID) scenario=\(scenario) appClass=\(appClass.rawValue) tier=\(tier) reason=\(reason) inline=\(inline) rejection=\(rejection)"
    }
}

enum OverlayGeometryCorpus {
    static let defaultScreen = CGRect(x: 0, y: 0, width: 1_000, height: 1_000)
    static let defaultContentSize = NSSize(width: 180, height: 18)

    static let fixtures: [OverlayGeometryCorpusFixture] = [
        OverlayGeometryCorpusFixture(
            id: "zero-rect",
            scenario: "zero rect",
            appClass: .nativeEditor,
            app: nativeEditorApp,
            inputRects: OverlayGeometryInputRects(
                caretRect: CGRect(x: 220, y: 260, width: 0, height: 0),
                focusedElementRect: nil,
                previousGlyphRect: nil,
                nextGlyphRect: nil,
                lineReferenceRect: nil
            ),
            selectedRange: NSRange(location: 12, length: 0),
            textBeforeCursor: syntheticText,
            caretGeometryQuality: .directCaret,
            observedCharacterWidth: nil,
            captureSources: [.accessibility],
            screenFrame: defaultScreen,
            visibleFrame: defaultScreen,
            screenFrames: [defaultScreen],
            contentSize: defaultContentSize,
            expected: OverlayGeometryCorpusExpectation(
                tier: .mirrorWindow,
                reason: "rejected-empty",
                validation: OverlayGeometryValidationExpectation(
                    focusedElementRect: nil,
                    caretRect: nil,
                    previousGlyphRect: nil,
                    nextGlyphRect: nil,
                    lineReferenceRect: nil
                ),
                inlineSource: nil,
                inlineRejectionReason: "missing-valid-text-metrics"
            )
        ),
        OverlayGeometryCorpusFixture(
            id: "upper-left-fallback-rect",
            scenario: "upper-left fallback rect",
            appClass: .nativeEditor,
            app: nativeEditorApp,
            inputRects: OverlayGeometryInputRects(
                caretRect: nil,
                focusedElementRect: CGRect(x: 0, y: 0, width: 500, height: 120),
                previousGlyphRect: nil,
                nextGlyphRect: nil,
                lineReferenceRect: nil
            ),
            selectedRange: NSRange(location: 12, length: 0),
            textBeforeCursor: syntheticText,
            caretGeometryQuality: .elementFrame,
            observedCharacterWidth: nil,
            captureSources: [.accessibility],
            screenFrame: defaultScreen,
            visibleFrame: defaultScreen,
            screenFrames: [defaultScreen],
            contentSize: defaultContentSize,
            expected: OverlayGeometryCorpusExpectation(
                tier: .mirrorWindow,
                reason: "rejected-zero-origin",
                validation: OverlayGeometryValidationExpectation(
                    focusedElementRect: nil,
                    caretRect: nil,
                    previousGlyphRect: nil,
                    nextGlyphRect: nil,
                    lineReferenceRect: nil
                ),
                inlineSource: nil,
                inlineRejectionReason: "missing-valid-text-metrics"
            )
        ),
        OverlayGeometryCorpusFixture(
            id: "outside-all-screens",
            scenario: "rect outside all screens",
            appClass: .nativeEditor,
            app: nativeEditorApp,
            inputRects: OverlayGeometryInputRects(
                caretRect: CGRect(x: 5_000, y: 5_000, width: 2, height: 20),
                focusedElementRect: nil,
                previousGlyphRect: nil,
                nextGlyphRect: nil,
                lineReferenceRect: nil
            ),
            selectedRange: NSRange(location: 12, length: 0),
            textBeforeCursor: syntheticText,
            caretGeometryQuality: .directCaret,
            observedCharacterWidth: nil,
            captureSources: [.accessibility],
            screenFrame: defaultScreen,
            visibleFrame: defaultScreen,
            screenFrames: [defaultScreen],
            contentSize: defaultContentSize,
            expected: OverlayGeometryCorpusExpectation(
                tier: .mirrorWindow,
                reason: "rejected-outside-screen",
                validation: OverlayGeometryValidationExpectation(
                    focusedElementRect: nil,
                    caretRect: nil,
                    previousGlyphRect: nil,
                    nextGlyphRect: nil,
                    lineReferenceRect: nil
                ),
                inlineSource: nil,
                inlineRejectionReason: "missing-valid-text-metrics"
            )
        ),
        OverlayGeometryCorpusFixture(
            id: "retina-physical-pixel-rect",
            scenario: "retina physical-pixel rect",
            appClass: .nativeEditor,
            app: nativeEditorApp,
            inputRects: OverlayGeometryInputRects(
                caretRect: CGRect(x: 1_600, y: 960, width: 4, height: 36),
                focusedElementRect: nil,
                previousGlyphRect: nil,
                nextGlyphRect: nil,
                lineReferenceRect: nil
            ),
            selectedRange: NSRange(location: 12, length: 0),
            textBeforeCursor: syntheticText,
            caretGeometryQuality: .directCaret,
            observedCharacterWidth: nil,
            captureSources: [.accessibility],
            screenFrame: defaultScreen,
            visibleFrame: defaultScreen,
            screenFrames: [defaultScreen],
            contentSize: defaultContentSize,
            expected: OverlayGeometryCorpusExpectation(
                tier: .visualInlineOverlay,
                reason: "physical-to-points-2x",
                validation: OverlayGeometryValidationExpectation(
                    focusedElementRect: nil,
                    caretRect: CGRect(x: 800, y: 502, width: 2, height: 18),
                    previousGlyphRect: nil,
                    nextGlyphRect: nil,
                    lineReferenceRect: nil
                ),
                inlineSource: .exactAX,
                inlineRejectionReason: nil
            )
        ),
        OverlayGeometryCorpusFixture(
            id: "wide-caret-normalization",
            scenario: "caret rect too wide",
            appClass: .nativeEditor,
            app: nativeEditorApp,
            inputRects: OverlayGeometryInputRects(
                caretRect: CGRect(x: 420, y: 500, width: 120, height: 24),
                focusedElementRect: CGRect(x: 300, y: 460, width: 300, height: 100),
                previousGlyphRect: nil,
                nextGlyphRect: nil,
                lineReferenceRect: nil
            ),
            selectedRange: NSRange(location: 12, length: 0),
            textBeforeCursor: syntheticText,
            caretGeometryQuality: .directCaret,
            observedCharacterWidth: nil,
            captureSources: [.accessibility],
            screenFrame: defaultScreen,
            visibleFrame: defaultScreen,
            screenFrames: [defaultScreen],
            contentSize: defaultContentSize,
            expected: OverlayGeometryCorpusExpectation(
                tier: .visualInlineOverlay,
                reason: "caret-width-normalized",
                validation: OverlayGeometryValidationExpectation(
                    focusedElementRect: CGRect(x: 300, y: 440, width: 300, height: 100),
                    caretRect: CGRect(x: 420, y: 476, width: 1, height: 24),
                    previousGlyphRect: nil,
                    nextGlyphRect: nil,
                    lineReferenceRect: nil
                ),
                inlineSource: .exactAX,
                inlineRejectionReason: nil
            )
        ),
        OverlayGeometryCorpusFixture(
            id: "caret-far-from-focused-element",
            scenario: "caret rect far from focused element",
            appClass: .nativeEditor,
            app: nativeEditorApp,
            inputRects: OverlayGeometryInputRects(
                caretRect: CGRect(x: 900, y: 900, width: 2, height: 20),
                focusedElementRect: CGRect(x: 100, y: 100, width: 300, height: 80),
                previousGlyphRect: nil,
                nextGlyphRect: nil,
                lineReferenceRect: nil
            ),
            selectedRange: NSRange(location: 12, length: 0),
            textBeforeCursor: syntheticText,
            caretGeometryQuality: .directCaret,
            observedCharacterWidth: nil,
            captureSources: [.accessibility],
            screenFrame: defaultScreen,
            visibleFrame: defaultScreen,
            screenFrames: [defaultScreen],
            contentSize: defaultContentSize,
            expected: OverlayGeometryCorpusExpectation(
                tier: .visualInlineOverlay,
                reason: "rejected-far-from-field",
                validation: OverlayGeometryValidationExpectation(
                    focusedElementRect: CGRect(x: 100, y: 820, width: 300, height: 80),
                    caretRect: nil,
                    previousGlyphRect: nil,
                    nextGlyphRect: nil,
                    lineReferenceRect: nil
                ),
                inlineSource: .textBoxEstimate,
                inlineRejectionReason: nil
            )
        ),
        OverlayGeometryCorpusFixture(
            id: "focused-element-too-small",
            scenario: "focused element rect too small",
            appClass: .nativeEditor,
            app: nativeEditorApp,
            inputRects: OverlayGeometryInputRects(
                caretRect: nil,
                focusedElementRect: CGRect(x: 120, y: 500, width: 10, height: 10),
                previousGlyphRect: nil,
                nextGlyphRect: nil,
                lineReferenceRect: nil
            ),
            selectedRange: NSRange(location: 12, length: 0),
            textBeforeCursor: syntheticText,
            caretGeometryQuality: .elementFrame,
            observedCharacterWidth: nil,
            captureSources: [.accessibility],
            screenFrame: defaultScreen,
            visibleFrame: defaultScreen,
            screenFrames: [defaultScreen],
            contentSize: defaultContentSize,
            expected: OverlayGeometryCorpusExpectation(
                tier: .simpleCaretPopup,
                reason: "invalid-focused-element-fallback",
                validation: OverlayGeometryValidationExpectation(
                    focusedElementRect: CGRect(x: 120, y: 490, width: 10, height: 10),
                    caretRect: nil,
                    previousGlyphRect: nil,
                    nextGlyphRect: nil,
                    lineReferenceRect: nil
                ),
                inlineSource: nil,
                inlineRejectionReason: "invalid-focused-element-fallback"
            )
        ),
        OverlayGeometryCorpusFixture(
            id: "multi-monitor-negative-origin",
            scenario: "multi-monitor negative origin",
            appClass: .multiMonitorEditor,
            app: nativeEditorApp,
            inputRects: OverlayGeometryInputRects(
                caretRect: CGRect(x: -800, y: 500, width: 2, height: 20),
                focusedElementRect: CGRect(x: -900, y: 460, width: 300, height: 100),
                previousGlyphRect: nil,
                nextGlyphRect: nil,
                lineReferenceRect: nil
            ),
            selectedRange: NSRange(location: 12, length: 0),
            textBeforeCursor: syntheticText,
            caretGeometryQuality: .directCaret,
            observedCharacterWidth: nil,
            captureSources: [.accessibility],
            screenFrame: defaultScreen,
            visibleFrame: CGRect(x: -1_000, y: 0, width: 1_000, height: 1_000),
            screenFrames: [
                CGRect(x: -1_000, y: 0, width: 1_000, height: 1_000),
                defaultScreen
            ],
            contentSize: defaultContentSize,
            expected: OverlayGeometryCorpusExpectation(
                tier: .visualInlineOverlay,
                reason: "accepted-negative-origin-screen",
                validation: OverlayGeometryValidationExpectation(
                    focusedElementRect: CGRect(x: -900, y: 440, width: 300, height: 100),
                    caretRect: CGRect(x: -800, y: 480, width: 2, height: 20),
                    previousGlyphRect: nil,
                    nextGlyphRect: nil,
                    lineReferenceRect: nil
                ),
                inlineSource: .exactAX,
                inlineRejectionReason: nil
            )
        ),
        OverlayGeometryCorpusFixture(
            id: "browser-line-metric-quirk",
            scenario: "browser editor line-metric quirk",
            appClass: .browserEditor,
            app: browserEditorApp,
            inputRects: OverlayGeometryInputRects(
                caretRect: CGRect(x: 768, y: 378, width: 0, height: 17),
                focusedElementRect: CGRect(x: 768, y: 378, width: 625, height: 2),
                previousGlyphRect: nil,
                nextGlyphRect: nil,
                lineReferenceRect: nil
            ),
            selectedRange: NSRange(location: 12, length: 0),
            textBeforeCursor: syntheticText,
            caretGeometryQuality: .lineMetric,
            observedCharacterWidth: nil,
            captureSources: [.accessibility],
            screenFrame: defaultScreen,
            visibleFrame: defaultScreen,
            screenFrames: [defaultScreen],
            contentSize: defaultContentSize,
            expected: OverlayGeometryCorpusExpectation(
                tier: .visualInlineOverlay,
                reason: "line-metric-collapsed-caret",
                validation: OverlayGeometryValidationExpectation(
                    focusedElementRect: CGRect(x: 768, y: 620, width: 625, height: 2),
                    caretRect: CGRect(x: 768, y: 605, width: 1, height: 17),
                    previousGlyphRect: nil,
                    nextGlyphRect: nil,
                    lineReferenceRect: nil
                ),
                inlineSource: .exactAX,
                inlineRejectionReason: nil
            )
        ),
        OverlayGeometryCorpusFixture(
            id: "ocr-fallback-rect",
            scenario: "OCR fallback rect",
            appClass: .ocrRecoveredEditor,
            app: nativeEditorApp,
            inputRects: OverlayGeometryInputRects(
                caretRect: CGRect(x: 820, y: 780, width: 2, height: 18),
                focusedElementRect: CGRect(x: 100, y: 100, width: 250, height: 70),
                previousGlyphRect: nil,
                nextGlyphRect: nil,
                lineReferenceRect: nil
            ),
            selectedRange: NSRange(location: 12, length: 0),
            textBeforeCursor: syntheticText,
            caretGeometryQuality: .screenOCR,
            observedCharacterWidth: nil,
            captureSources: [.accessibility, .screenOCR],
            screenFrame: defaultScreen,
            visibleFrame: defaultScreen,
            screenFrames: [defaultScreen],
            contentSize: defaultContentSize,
            expected: OverlayGeometryCorpusExpectation(
                tier: .visualInlineOverlay,
                reason: "screen-ocr-proximity-bypass",
                validation: OverlayGeometryValidationExpectation(
                    focusedElementRect: CGRect(x: 100, y: 830, width: 250, height: 70),
                    caretRect: CGRect(x: 820, y: 202, width: 2, height: 18),
                    previousGlyphRect: nil,
                    nextGlyphRect: nil,
                    lineReferenceRect: nil
                ),
                inlineSource: .exactAX,
                inlineRejectionReason: nil
            )
        )
    ]

    static func run(
        fixture: OverlayGeometryCorpusFixture,
        tier: PreviewPresentationTier
    ) -> OverlayGeometryCorpusResult {
        let context = fixture.makeContext()
        let validation = validator(for: fixture).validate(context: context)
        let resolution = InlinePreviewGeometry.resolve(
            context: context,
            contentSize: fixture.contentSize,
            screenFrame: fixture.screenFrame,
            visibleFrame: fixture.visibleFrame,
            screenFrames: fixture.screenFrames,
            allowsLineWrapPlacement: true
        )

        return OverlayGeometryCorpusResult(
            fixtureID: fixture.id,
            scenario: fixture.scenario,
            appClass: fixture.appClass,
            tier: tier,
            reason: fixture.expected.reason,
            validation: validation,
            inlineSource: resolution.layout?.source,
            inlineRejectionReason: resolution.rejectionReason
        )
    }

    static func validator(for fixture: OverlayGeometryCorpusFixture) -> OverlayGeometryValidator {
        OverlayGeometryValidator(
            screenFrame: fixture.screenFrame,
            visibleFrame: fixture.visibleFrame,
            screenFrames: fixture.screenFrames
        )
    }

    private static let nativeEditorApp = AppIdentity(
        bundleID: "com.apple.TextEdit",
        displayName: "TextEdit",
        processID: 1
    )
    private static let browserEditorApp = AppIdentity(
        bundleID: "com.google.Chrome",
        displayName: "Browser",
        processID: 2
    )
    private static let syntheticText = "synthetic corpus prefix"
}
