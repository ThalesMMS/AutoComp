import AutoCompCore
@testable import AutoCompApp
import XCTest

@MainActor
final class FocusDebugOverlayControllerTests: XCTestCase {
    func testOptionsAreDisabledByDefaultAndEnabledByFlag() {
        XCTAssertFalse(FocusDebugOverlayOptions.isEnabled(arguments: [], environment: [:]))
        XCTAssertTrue(FocusDebugOverlayOptions.isEnabled(arguments: ["AutoComp", "--focus-debug-overlay"], environment: [:]))
        XCTAssertTrue(FocusDebugOverlayOptions.isEnabled(arguments: [], environment: ["AUTOCOMP_DEBUG_FOCUS_OVERLAY": "1"]))
        XCTAssertFalse(FocusDebugOverlayOptions.isEnabled(arguments: [], environment: ["AUTOCOMP_DEBUG_FOCUS_OVERLAY": "0"]))
    }

    func testSnapshotUsesLogQualityLabelsAndDoesNotExposeUserText() throws {
        let stableIdentity = StableFieldIdentity(
            bundleID: "com.apple.TextEdit",
            processID: 42,
            domain: "example.com",
            role: "AXTextArea",
            subrole: nil,
            roundedFocusedElementFrame: CGRect(x: 100, y: 100, width: 500, height: 40),
            focusChangeSequence: 7
        )
        let context = TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 42),
            domain: "example.com",
            focusedElementID: "field",
            stableFieldIdentity: stableIdentity,
            textBeforeCursor: "secret user text",
            selectedRange: NSRange(location: 16, length: 0),
            caretRect: CGRect(x: 180, y: 110, width: 1, height: 18),
            focusedElementRect: CGRect(x: 100, y: 100, width: 500, height: 40),
            previousGlyphRect: CGRect(x: 170, y: 110, width: 9, height: 18),
            lineReferenceRect: CGRect(x: 100, y: 112, width: 500, height: 18),
            caretGeometryQuality: .screenOCR,
            captureSources: [.accessibility, .screenOCR]
        )
        let visualSession = VisualContextSession(
            identity: stableIdentity,
            state: .ready,
            statusMessage: "Visual context ready"
        )

        let snapshot = try XCTUnwrap(FocusDebugOverlaySnapshot.make(
            context: context,
            tier: .visualInlineOverlay,
            visualContextSession: visualSession,
            screenFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
            visibleFrame: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
            screenFrames: [CGRect(x: 0, y: 0, width: 1_000, height: 1_000)]
        ))

        XCTAssertEqual(
            Set(snapshot.rectangles.map(\.kind)),
            [.focusedElement, .caret, .previousGlyph, .lineReference, .screenOCRRegion]
        )
        let labels = snapshot.labels.joined(separator: "\n")
        XCTAssertTrue(labels.contains("source=accessibility,screenOCR"))
        XCTAssertTrue(labels.contains("quality=screenOCR"))
        XCTAssertTrue(labels.contains("tier=visualInlineOverlay"))
        XCTAssertTrue(labels.contains("visual=ready source=visualContext-ocr"))
        XCTAssertTrue(labels.contains("bundle=com.apple.TextEdit"))
        XCTAssertTrue(labels.contains("seq=7"))
        XCTAssertFalse(labels.contains("secret user text"))
    }

    func testPreviewCoordinatorShowsAndHidesFocusDebugOverlayWithResolvedTier() {
        let native = RecordingPreviewPresenter(canPresentResult: false)
        let visual = RecordingPreviewPresenter(canPresentResult: true)
        let mirror = RecordingPreviewPresenter(canPresentResult: true)
        let focusDebug = RecordingFocusDebugOverlayPresenter()
        let coordinator = PreviewCoordinator(
            nativeInlinePresenter: native,
            visualInlinePresenter: visual,
            mirrorWindowPresenter: mirror,
            focusDebugOverlayPresenter: focusDebug
        )

        coordinator.show(suggestion(), for: context(), mode: .inline)
        coordinator.update(suggestion(), for: context(), mode: .disabled)
        coordinator.hide()

        XCTAssertEqual(focusDebug.showTiers, [.visualInlineOverlay])
        XCTAssertEqual(focusDebug.showContexts.map(\.focusedElementID), ["field"])
        XCTAssertEqual(focusDebug.hideCount, 2)
    }

    private func suggestion() -> Suggestion {
        Suggestion(baseContextID: UUID(), visibleText: " continuation", latencyMs: 12)
    }

    private func context() -> TextContext {
        TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: "Hello",
            selectedRange: NSRange(location: 5, length: 0),
            caretRect: CGRect(x: 100, y: 100, width: 2, height: 20)
        )
    }
}

@MainActor
private final class RecordingPreviewPresenter: NativeInlineSuggestionPresenting, VisualInlineSuggestionPresenting {
    private let canPresentResult: Bool
    private(set) var showCount = 0
    private(set) var updateCount = 0
    private(set) var hideCount = 0

    init(canPresentResult: Bool) {
        self.canPresentResult = canPresentResult
    }

    func canPresent(_ suggestion: Suggestion, for context: TextContext) -> Bool {
        canPresentResult
    }

    func show(_ suggestion: Suggestion, for context: TextContext) {
        showCount += 1
    }

    func update(_ suggestion: Suggestion, for context: TextContext) {
        updateCount += 1
    }

    func hide() {
        hideCount += 1
    }
}

@MainActor
private final class RecordingFocusDebugOverlayPresenter: FocusDebugOverlayPresenting {
    private(set) var showContexts: [TextContext] = []
    private(set) var showTiers: [PreviewPresentationTier] = []
    private(set) var hideCount = 0

    func show(context: TextContext, tier: PreviewPresentationTier) {
        showContexts.append(context)
        showTiers.append(tier)
    }

    func hide() {
        hideCount += 1
    }
}
