import AppKit
import AutoCompCore
@testable import AutoCompApp
import XCTest

@MainActor
final class PreviewCoordinatorTests: XCTestCase {
    func testInlineUsesVisualOverlayWhenNativeInlineIsUnavailable() {
        let native = RecordingPreviewPresenter(canPresentResult: false)
        let visual = RecordingPreviewPresenter(canPresentResult: true)
        let simple = RecordingPreviewPresenter(canPresentResult: true)
        let mirror = RecordingPreviewPresenter(canPresentResult: true)
        let coordinator = PreviewCoordinator(
            nativeInlinePresenter: native,
            visualInlinePresenter: visual,
            mirrorWindowPresenter: mirror,
            simpleCaretPopupPresenter: simple
        )

        coordinator.show(suggestion(), for: context(), mode: .inline)

        XCTAssertEqual(coordinator.activeTier, .visualInlineOverlay)
        XCTAssertEqual(visual.showCount, 1)
        XCTAssertEqual(simple.showCount, 0)
        XCTAssertEqual(mirror.showCount, 0)
    }

    func testNativeInlineTakesPrecedenceOverVisualOverlay() {
        let native = RecordingPreviewPresenter(canPresentResult: true)
        let visual = RecordingPreviewPresenter(canPresentResult: true)
        let simple = RecordingPreviewPresenter(canPresentResult: true)
        let mirror = RecordingPreviewPresenter(canPresentResult: true)
        let coordinator = PreviewCoordinator(
            nativeInlinePresenter: native,
            visualInlinePresenter: visual,
            mirrorWindowPresenter: mirror,
            simpleCaretPopupPresenter: simple
        )

        coordinator.show(suggestion(), for: context(), mode: .inline)

        XCTAssertEqual(coordinator.activeTier, .nativeInline)
        XCTAssertEqual(native.showCount, 1)
        XCTAssertEqual(visual.showCount, 0)
        XCTAssertEqual(simple.showCount, 0)
        XCTAssertEqual(mirror.showCount, 0)
    }

    func testInlineFallsBackToMirrorWindowWhenNoInlineTierCanPresent() {
        let native = RecordingPreviewPresenter(canPresentResult: false)
        let visual = RecordingPreviewPresenter(canPresentResult: false)
        let simple = RecordingPreviewPresenter(canPresentResult: false)
        let mirror = RecordingPreviewPresenter(canPresentResult: true)
        let coordinator = PreviewCoordinator(
            nativeInlinePresenter: native,
            visualInlinePresenter: visual,
            mirrorWindowPresenter: mirror,
            simpleCaretPopupPresenter: simple
        )

        coordinator.show(suggestion(), for: context(caretRect: nil), mode: .inline)

        XCTAssertEqual(coordinator.activeTier, .mirrorWindow)
        XCTAssertEqual(mirror.showCount, 1)
    }

    func testInlineUsesSimpleCaretPopupBeforeMirrorWindow() {
        let native = RecordingPreviewPresenter(canPresentResult: false)
        let visual = RecordingPreviewPresenter(canPresentResult: false)
        let simple = RecordingPreviewPresenter(canPresentResult: true)
        let mirror = RecordingPreviewPresenter(canPresentResult: true)
        let coordinator = PreviewCoordinator(
            nativeInlinePresenter: native,
            visualInlinePresenter: visual,
            mirrorWindowPresenter: mirror,
            simpleCaretPopupPresenter: simple
        )

        coordinator.show(suggestion(), for: context(), mode: .inline)

        XCTAssertEqual(coordinator.activeTier, .simpleCaretPopup)
        XCTAssertEqual(simple.showCount, 1)
        XCTAssertEqual(mirror.showCount, 0)
    }

    func testMultiSuggestionPopupTakesPrecedenceOverInlineAndMirrorPresenters() {
        let native = RecordingPreviewPresenter(canPresentResult: true)
        let multi = RecordingPreviewPresenter(canPresentResult: true)
        let visual = RecordingPreviewPresenter(canPresentResult: true)
        let simple = RecordingPreviewPresenter(canPresentResult: true)
        let mirror = RecordingPreviewPresenter(canPresentResult: true)
        let coordinator = PreviewCoordinator(
            nativeInlinePresenter: native,
            visualInlinePresenter: visual,
            mirrorWindowPresenter: mirror,
            multiSuggestionPopupPresenter: multi,
            simpleCaretPopupPresenter: simple
        )

        coordinator.show(multiSuggestion(), for: context(), mode: .mirrorWindow)

        XCTAssertEqual(coordinator.activeTier, .multiSuggestionPopup)
        XCTAssertEqual(multi.showCount, 1)
        XCTAssertEqual(native.showCount, 0)
        XCTAssertEqual(visual.showCount, 0)
        XCTAssertEqual(simple.showCount, 0)
        XCTAssertEqual(mirror.showCount, 0)
    }

    func testSafeOverlayModeUsesSimplePopupForTextEditAndChromeTextarea() {
        for context in [
            context(),
            context(
                app: AppIdentity(bundleID: "com.google.Chrome", displayName: "Chrome", processID: 2),
                domain: "example.com"
            )
        ] {
            let native = RecordingPreviewPresenter(canPresentResult: true)
            let multi = RecordingPreviewPresenter(canPresentResult: true)
            let visual = RecordingPreviewPresenter(canPresentResult: true)
            let simple = RecordingPreviewPresenter(canPresentResult: true)
            let mirror = RecordingPreviewPresenter(canPresentResult: true)
            let coordinator = PreviewCoordinator(
                nativeInlinePresenter: native,
                visualInlinePresenter: visual,
                mirrorWindowPresenter: mirror,
                multiSuggestionPopupPresenter: multi,
                simpleCaretPopupPresenter: simple,
                safeOverlayModeEnabled: true
            )

            coordinator.show(multiSuggestion(), for: context, mode: .inline)

            XCTAssertEqual(coordinator.activeTier, .simpleCaretPopup)
            XCTAssertEqual(simple.showCount, 1)
            XCTAssertEqual(native.showCount, 0)
            XCTAssertEqual(multi.showCount, 0)
            XCTAssertEqual(visual.showCount, 0)
            XCTAssertEqual(mirror.showCount, 0)
        }
    }

    func testSafeOverlayModeFallsBackToMirrorWhenSimplePopupCannotPresent() {
        let native = RecordingPreviewPresenter(canPresentResult: true)
        let multi = RecordingPreviewPresenter(canPresentResult: true)
        let visual = RecordingPreviewPresenter(canPresentResult: true)
        let simple = RecordingPreviewPresenter(canPresentResult: false)
        let mirror = RecordingPreviewPresenter(canPresentResult: true)
        let coordinator = PreviewCoordinator(
            nativeInlinePresenter: native,
            visualInlinePresenter: visual,
            mirrorWindowPresenter: mirror,
            multiSuggestionPopupPresenter: multi,
            simpleCaretPopupPresenter: simple,
            safeOverlayModeEnabled: true
        )

        coordinator.show(suggestion(), for: context(caretRect: nil), mode: .inline)

        XCTAssertEqual(coordinator.activeTier, .mirrorWindow)
        XCTAssertEqual(mirror.showCount, 1)
        XCTAssertEqual(native.showCount, 0)
        XCTAssertEqual(multi.showCount, 0)
        XCTAssertEqual(visual.showCount, 0)
    }

    func testUpdatingExistingSimpleCaretPopupKeepsSameTier() {
        let native = RecordingPreviewPresenter(canPresentResult: false)
        let visual = RecordingPreviewPresenter(canPresentResult: false)
        let simple = RecordingPreviewPresenter(canPresentResult: true)
        let mirror = RecordingPreviewPresenter(canPresentResult: true)
        let coordinator = PreviewCoordinator(
            nativeInlinePresenter: native,
            visualInlinePresenter: visual,
            mirrorWindowPresenter: mirror,
            simpleCaretPopupPresenter: simple
        )

        coordinator.show(suggestion(), for: context(), mode: .inline)
        coordinator.update(suggestion(visibleText: " next"), for: context(), mode: .inline)

        XCTAssertEqual(coordinator.activeTier, .simpleCaretPopup)
        XCTAssertEqual(simple.showCount, 1)
        XCTAssertEqual(simple.updateCount, 1)
        XCTAssertEqual(mirror.showCount, 0)
    }

    func testInlineUsesVisualOverlayWithFocusedElementFallback() {
        let native = RecordingPreviewPresenter(canPresentResult: false)
        let mirror = RecordingPreviewPresenter(canPresentResult: true)
        let coordinator = PreviewCoordinator(
            nativeInlinePresenter: native,
            visualInlinePresenter: VisualInlineOverlayPresenter(),
            mirrorWindowPresenter: mirror
        )

        let tier = coordinator.resolveTier(
            for: suggestion(),
            context: context(
                caretRect: nil,
                focusedElementRect: CGRect(x: 120, y: 500, width: 520, height: 48)
            ),
            mode: .inline
        )

        XCTAssertEqual(tier, .visualInlineOverlay)
        XCTAssertEqual(mirror.showCount, 0)
    }

    func testMirrorModeBypassesInlinePresenters() {
        let native = RecordingPreviewPresenter(canPresentResult: true)
        let visual = RecordingPreviewPresenter(canPresentResult: true)
        let mirror = RecordingPreviewPresenter(canPresentResult: true)
        let coordinator = PreviewCoordinator(
            nativeInlinePresenter: native,
            visualInlinePresenter: visual,
            mirrorWindowPresenter: mirror
        )

        coordinator.show(suggestion(), for: context(), mode: .mirrorWindow)

        XCTAssertEqual(coordinator.activeTier, .mirrorWindow)
        XCTAssertEqual(native.showCount, 0)
        XCTAssertEqual(visual.showCount, 0)
        XCTAssertEqual(mirror.showCount, 1)
    }

    func testDisabledModeHidesActivePresenter() {
        let native = RecordingPreviewPresenter(canPresentResult: false)
        let visual = RecordingPreviewPresenter(canPresentResult: true)
        let simple = RecordingPreviewPresenter(canPresentResult: true)
        let mirror = RecordingPreviewPresenter(canPresentResult: true)
        let indicator = RecordingActivationIndicatorPresenter()
        let coordinator = PreviewCoordinator(
            nativeInlinePresenter: native,
            visualInlinePresenter: visual,
            mirrorWindowPresenter: mirror,
            simpleCaretPopupPresenter: simple,
            activationIndicator: indicator
        )

        coordinator.show(suggestion(), for: context(), mode: .inline)
        coordinator.update(suggestion(), for: context(), mode: .disabled)

        XCTAssertEqual(coordinator.activeTier, .disabled)
        XCTAssertGreaterThanOrEqual(visual.hideCount, 1)
        XCTAssertGreaterThanOrEqual(simple.hideCount, 1)
        XCTAssertEqual(mirror.showCount, 0)
        XCTAssertEqual(indicator.hideCount, 1)
    }

    func testActivationIndicatorTracksResolvedPreviewActivity() {
        let native = RecordingPreviewPresenter(canPresentResult: false)
        let visual = RecordingPreviewPresenter(canPresentResult: true)
        let mirror = RecordingPreviewPresenter(canPresentResult: true)
        let indicator = RecordingActivationIndicatorPresenter()
        let coordinator = PreviewCoordinator(
            nativeInlinePresenter: native,
            visualInlinePresenter: visual,
            mirrorWindowPresenter: mirror,
            activationIndicator: indicator
        )

        coordinator.show(suggestion(), for: context(), mode: .inline)
        coordinator.update(suggestion(), for: context(), mode: .mirrorWindow)
        coordinator.hide()

        XCTAssertEqual(indicator.showModes, [.inline, .mirrorWindow])
        XCTAssertEqual(indicator.hideCount, 1)
    }

    func testShortcutAwarePresenterMirrorsResolvedPreviewActivity() {
        let native = RecordingPreviewPresenter(canPresentResult: false)
        let visual = RecordingPreviewPresenter(canPresentResult: true)
        let mirror = RecordingPreviewPresenter(canPresentResult: true)
        let coordinator = PreviewCoordinator(
            nativeInlinePresenter: native,
            visualInlinePresenter: visual,
            mirrorWindowPresenter: mirror
        )
        var activeStates: [Bool] = []
        let presenter = ShortcutAwareSuggestionPresenter(
            previewCoordinator: coordinator,
            setSuggestionActive: { activeStates.append($0) }
        )

        presenter.show(suggestion(), for: context(), mode: .inline)
        presenter.update(suggestion(), for: context(), mode: .disabled)

        XCTAssertEqual(activeStates, [true, false])
    }

    func testFloatingSuggestionPanelDoesNotStealFocusOrAutoHideWhenAppIsInactive() {
        let panel = FloatingSuggestionPanelFactory.makePanel(
            contentRect: CGRect(x: 0, y: 0, width: 120, height: 18)
        )

        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertFalse(panel.hidesOnDeactivate)
        XCTAssertFalse(panel.isReleasedWhenClosed)
        XCTAssertTrue(panel.ignoresMouseEvents)
        XCTAssertEqual(panel.animationBehavior, .none)
        XCTAssertEqual(panel.level, NSWindow.Level(rawValue: NSWindow.Level.statusBar.rawValue + 2))
        XCTAssertTrue(panel.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(panel.collectionBehavior.contains(.stationary))
        XCTAssertTrue(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(panel.collectionBehavior.contains(.ignoresCycle))
        XCTAssertFalse(panel.collectionBehavior.contains(.transient))
    }

    func testSimpleCaretPopupPanelUsesPopupLevel() {
        let panel = FloatingSuggestionPanelFactory.makePanel(
            contentRect: CGRect(x: 0, y: 0, width: 180, height: 32),
            level: .popUpMenu
        )

        XCTAssertEqual(panel.level, .popUpMenu)
        XCTAssertFalse(panel.canBecomeKey)
        XCTAssertFalse(panel.canBecomeMain)
        XCTAssertTrue(panel.ignoresMouseEvents)
    }

    private func suggestion(visibleText: String = " continuation") -> Suggestion {
        Suggestion(baseContextID: UUID(), visibleText: visibleText, latencyMs: 12)
    }

    private func multiSuggestion() -> Suggestion {
        Suggestion(
            baseContextID: UUID(),
            visibleText: " first",
            alternatives: [
                SuggestionAlternative(visibleText: " first"),
                SuggestionAlternative(visibleText: " second"),
                SuggestionAlternative(visibleText: " third")
            ],
            latencyMs: 12
        )
    }

    private func context(
        app: AppIdentity = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
        domain: String? = nil,
        caretRect: CGRect? = CGRect(x: 100, y: 100, width: 2, height: 20),
        focusedElementRect: CGRect? = nil
    ) -> TextContext {
        TextContext(
            app: app,
            domain: domain,
            focusedElementID: "field",
            textBeforeCursor: "Hello",
            selectedRange: NSRange(location: 5, length: 0),
            caretRect: caretRect,
            focusedElementRect: focusedElementRect
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
private final class RecordingActivationIndicatorPresenter: ActivationIndicatorPresenting {
    private(set) var showModes: [SuggestionDisplayMode] = []
    private(set) var hideCount = 0

    func show(for context: TextContext, displayMode: SuggestionDisplayMode) {
        showModes.append(displayMode)
    }

    func hide() {
        hideCount += 1
    }
}
