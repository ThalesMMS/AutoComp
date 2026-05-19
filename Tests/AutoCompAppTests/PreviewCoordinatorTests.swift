import AutoCompCore
@testable import AutoCompApp
import XCTest

@MainActor
final class PreviewCoordinatorTests: XCTestCase {
    func testInlineUsesVisualOverlayWhenNativeInlineIsUnavailable() {
        let native = RecordingPreviewPresenter(canPresentResult: false)
        let visual = RecordingPreviewPresenter(canPresentResult: true)
        let mirror = RecordingPreviewPresenter(canPresentResult: true)
        let coordinator = PreviewCoordinator(
            nativeInlinePresenter: native,
            visualInlinePresenter: visual,
            mirrorWindowPresenter: mirror
        )

        coordinator.show(suggestion(), for: context(), mode: .inline)

        XCTAssertEqual(coordinator.activeTier, .visualInlineOverlay)
        XCTAssertEqual(visual.showCount, 1)
        XCTAssertEqual(mirror.showCount, 0)
    }

    func testNativeInlineTakesPrecedenceOverVisualOverlay() {
        let native = RecordingPreviewPresenter(canPresentResult: true)
        let visual = RecordingPreviewPresenter(canPresentResult: true)
        let mirror = RecordingPreviewPresenter(canPresentResult: true)
        let coordinator = PreviewCoordinator(
            nativeInlinePresenter: native,
            visualInlinePresenter: visual,
            mirrorWindowPresenter: mirror
        )

        coordinator.show(suggestion(), for: context(), mode: .inline)

        XCTAssertEqual(coordinator.activeTier, .nativeInline)
        XCTAssertEqual(native.showCount, 1)
        XCTAssertEqual(visual.showCount, 0)
        XCTAssertEqual(mirror.showCount, 0)
    }

    func testInlineDisablesPreviewWhenVisualInlineHasNoGeometry() {
        let native = RecordingPreviewPresenter(canPresentResult: false)
        let mirror = RecordingPreviewPresenter(canPresentResult: true)
        let coordinator = PreviewCoordinator(
            nativeInlinePresenter: native,
            visualInlinePresenter: VisualInlineOverlayPresenter(),
            mirrorWindowPresenter: mirror
        )

        coordinator.show(suggestion(), for: context(caretRect: nil), mode: .inline)

        XCTAssertEqual(coordinator.activeTier, .disabled)
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
        let mirror = RecordingPreviewPresenter(canPresentResult: true)
        let coordinator = PreviewCoordinator(
            nativeInlinePresenter: native,
            visualInlinePresenter: visual,
            mirrorWindowPresenter: mirror
        )

        coordinator.show(suggestion(), for: context(), mode: .inline)
        coordinator.update(suggestion(), for: context(), mode: .disabled)

        XCTAssertEqual(coordinator.activeTier, .disabled)
        XCTAssertGreaterThanOrEqual(visual.hideCount, 1)
        XCTAssertEqual(mirror.showCount, 0)
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

    private func suggestion() -> Suggestion {
        Suggestion(baseContextID: UUID(), visibleText: " continuation", latencyMs: 12)
    }

    private func context(
        caretRect: CGRect? = CGRect(x: 100, y: 100, width: 2, height: 20),
        focusedElementRect: CGRect? = nil
    ) -> TextContext {
        TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
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
