import AppKit
import AutoCompCore

@MainActor
final class PreviewCoordinator: SuggestionPresenter {
    private let nativeInlinePresenter: NativeInlineSuggestionPresenting
    private let multiSuggestionPopupPresenter: VisualInlineSuggestionPresenting
    private let visualInlinePresenter: VisualInlineSuggestionPresenting
    private let simpleCaretPopupPresenter: VisualInlineSuggestionPresenting
    private let mirrorWindowPresenter: SuggestionTierPresenting
    private let activationIndicator: ActivationIndicatorPresenting
    private let focusDebugOverlayPresenter: FocusDebugOverlayPresenting
    private let safeOverlayModeEnabled: Bool
    private let overlayRecoveryAdvisor: OverlayRecoveryAdvisor?

    private(set) var activeTier: PreviewPresentationTier = .disabled

    init(
        safeOverlayModeEnabled: Bool = SafeOverlayMode.isEnabled,
        overlayRecoveryAdvisor: OverlayRecoveryAdvisor? = nil,
        focusDebugOverlayPresenter: FocusDebugOverlayPresenting? = nil
    ) {
        let shortcutSettingsStore = KeyboardShortcutSettingsStore()
        let hintsProvider = OverlayShortcutHintsProvider()

        self.nativeInlinePresenter = UnavailableNativeInlinePresenter()
        self.multiSuggestionPopupPresenter = MultiSuggestionPopupPresenter(
            shortcutSettingsStore: shortcutSettingsStore,
            hintsProvider: hintsProvider
        )
        self.visualInlinePresenter = VisualInlineOverlayPresenter(
            shortcutSettingsStore: shortcutSettingsStore,
            hintsProvider: hintsProvider
        )
        self.simpleCaretPopupPresenter = SimpleCaretPopupSuggestionPresenter(
            shortcutSettingsStore: shortcutSettingsStore,
            hintsProvider: hintsProvider
        )
        self.mirrorWindowPresenter = MirrorWindowSuggestionPresenter(
            shortcutSettingsStore: shortcutSettingsStore,
            hintsProvider: hintsProvider
        )
        self.activationIndicator = ActivationIndicatorController()
        self.focusDebugOverlayPresenter = focusDebugOverlayPresenter ?? FocusDebugOverlayController()
        self.safeOverlayModeEnabled = safeOverlayModeEnabled
        self.overlayRecoveryAdvisor = overlayRecoveryAdvisor
    }

    init(
        nativeInlinePresenter: NativeInlineSuggestionPresenting,
        visualInlinePresenter: VisualInlineSuggestionPresenting,
        mirrorWindowPresenter: SuggestionTierPresenting,
        multiSuggestionPopupPresenter: VisualInlineSuggestionPresenting? = nil,
        simpleCaretPopupPresenter: VisualInlineSuggestionPresenting? = nil,
        activationIndicator: ActivationIndicatorPresenting? = nil,
        focusDebugOverlayPresenter: FocusDebugOverlayPresenting? = nil,
        safeOverlayModeEnabled: Bool = SafeOverlayMode.isEnabled,
        overlayRecoveryAdvisor: OverlayRecoveryAdvisor? = nil
    ) {
        let shortcutSettingsStore = KeyboardShortcutSettingsStore()
        let hintsProvider = OverlayShortcutHintsProvider()

        self.nativeInlinePresenter = nativeInlinePresenter
        self.multiSuggestionPopupPresenter = multiSuggestionPopupPresenter ?? MultiSuggestionPopupPresenter(
            shortcutSettingsStore: shortcutSettingsStore,
            hintsProvider: hintsProvider
        )
        self.visualInlinePresenter = visualInlinePresenter
        self.simpleCaretPopupPresenter = simpleCaretPopupPresenter ?? SimpleCaretPopupSuggestionPresenter(
            shortcutSettingsStore: shortcutSettingsStore,
            hintsProvider: hintsProvider
        )
        self.mirrorWindowPresenter = mirrorWindowPresenter
        self.activationIndicator = activationIndicator ?? ActivationIndicatorController()
        self.focusDebugOverlayPresenter = focusDebugOverlayPresenter ?? FocusDebugOverlayController()
        self.safeOverlayModeEnabled = safeOverlayModeEnabled
        self.overlayRecoveryAdvisor = overlayRecoveryAdvisor
    }

    func show(_ suggestion: Suggestion, for context: TextContext, mode: SuggestionDisplayMode) {
        present(suggestion, for: context, mode: mode, isUpdate: false)
    }

    func update(_ suggestion: Suggestion, for context: TextContext, mode: SuggestionDisplayMode) {
        present(suggestion, for: context, mode: mode, isUpdate: true)
    }

    func hide() {
        GeometryDebug.log("presenter-hide activeTier=\(activeTier)")
        activeTier = .disabled
        nativeInlinePresenter.hide()
        multiSuggestionPopupPresenter.hide()
        visualInlinePresenter.hide()
        simpleCaretPopupPresenter.hide()
        mirrorWindowPresenter.hide()
        activationIndicator.hide()
        focusDebugOverlayPresenter.hide()
    }

    func resolveTier(for suggestion: Suggestion, context: TextContext, mode: SuggestionDisplayMode) -> PreviewPresentationTier {
        guard mode != .disabled, !suggestion.visibleText.isEmpty else {
            return .disabled
        }
        if safeOverlayModeEnabled {
            switch mode {
            case .inline:
                if simpleCaretPopupPresenter.canPresent(suggestion, for: context) {
                    return .simpleCaretPopup
                }
                return .mirrorWindow
            case .mirrorWindow:
                return .mirrorWindow
            case .disabled:
                return .disabled
            }
        }

        if suggestion.hasMultipleAlternatives,
           multiSuggestionPopupPresenter.canPresent(suggestion, for: context) {
            return .multiSuggestionPopup
        }

        switch mode {
        case .inline:
            if nativeInlinePresenter.canPresent(suggestion, for: context) {
                return .nativeInline
            }
            if visualInlinePresenter.canPresent(suggestion, for: context) {
                return .visualInlineOverlay
            }
            if simpleCaretPopupPresenter.canPresent(suggestion, for: context) {
                return .simpleCaretPopup
            }
            return .mirrorWindow
        case .mirrorWindow:
            return .mirrorWindow
        case .disabled:
            return .disabled
        }
    }

    private func present(_ suggestion: Suggestion, for context: TextContext, mode: SuggestionDisplayMode, isUpdate: Bool) {
        let nextTier = resolveTier(for: suggestion, context: context, mode: mode)
        if safeOverlayModeEnabled {
            GeometryDebug.log("safe-overlay-mode active feature=preview-tier mode=\(mode.rawValue) resolvedTier=\(nextTier)")
        }
        recordOverlayRecoverySignal(tier: nextTier, mode: mode)
        GeometryDebug.log("presenter-present update=\(isUpdate) previousTier=\(String(describing: activeTier)) mode=\(mode.rawValue) resolvedTier=\(nextTier) app=\(context.app.displayName) bundle=\(context.app.bundleID) visibleLength=\((suggestion.visibleText as NSString).length) context=\(context.geometryDebugDescription)")
        let shouldUpdateExistingTier = isUpdate && activeTier == nextTier
        hidePresenters(except: nextTier)
        activeTier = nextTier
        if nextTier == .disabled {
            activationIndicator.hide()
            focusDebugOverlayPresenter.hide()
        } else {
            activationIndicator.show(
                for: context,
                displayMode: nextTier == .mirrorWindow ? .mirrorWindow : mode
            )
            focusDebugOverlayPresenter.show(context: context, tier: nextTier)
        }

        switch nextTier {
        case .nativeInline:
            shouldUpdateExistingTier
                ? nativeInlinePresenter.update(suggestion, for: context)
                : nativeInlinePresenter.show(suggestion, for: context)
        case .multiSuggestionPopup:
            shouldUpdateExistingTier
                ? multiSuggestionPopupPresenter.update(suggestion, for: context)
                : multiSuggestionPopupPresenter.show(suggestion, for: context)
        case .visualInlineOverlay:
            shouldUpdateExistingTier
                ? visualInlinePresenter.update(suggestion, for: context)
                : visualInlinePresenter.show(suggestion, for: context)
        case .simpleCaretPopup:
            shouldUpdateExistingTier
                ? simpleCaretPopupPresenter.update(suggestion, for: context)
                : simpleCaretPopupPresenter.show(suggestion, for: context)
        case .mirrorWindow:
            shouldUpdateExistingTier
                ? mirrorWindowPresenter.update(suggestion, for: context)
                : mirrorWindowPresenter.show(suggestion, for: context)
        case .disabled:
            break
        }
    }

    private func recordOverlayRecoverySignal(tier: PreviewPresentationTier, mode: SuggestionDisplayMode) {
        guard mode == .inline,
              !safeOverlayModeEnabled else {
            return
        }

        switch tier {
        case .nativeInline, .multiSuggestionPopup, .visualInlineOverlay:
            overlayRecoveryAdvisor?.recordAdvancedOverlaySuccess()
        case .simpleCaretPopup, .mirrorWindow:
            overlayRecoveryAdvisor?.recordAdvancedOverlayFallback()
        case .disabled:
            break
        }
    }

    private func hidePresenters(except tier: PreviewPresentationTier) {
        GeometryDebug.log("presenter-hide-except keep=\(tier) activeTier=\(String(describing: activeTier))")
        if tier != .nativeInline {
            nativeInlinePresenter.hide()
        }
        if tier != .multiSuggestionPopup {
            multiSuggestionPopupPresenter.hide()
        }
        if tier != .visualInlineOverlay {
            visualInlinePresenter.hide()
        }
        if tier != .simpleCaretPopup {
            simpleCaretPopupPresenter.hide()
        }
        if tier != .mirrorWindow {
            mirrorWindowPresenter.hide()
        }
    }
}

// Presenter implementations extracted to Services/Overlay/Presenters/OverlaySuggestionPresenters.swift


extension TextContext {
    var geometryDebugDescription: String {
        [
            "selectedRange=\(String(describing: selectedRange))",
            "focusedElementRect=\(String(describing: focusedElementRect))",
            "caretRect=\(String(describing: caretRect))",
            "previousGlyphRect=\(String(describing: previousGlyphRect))",
            "nextGlyphRect=\(String(describing: nextGlyphRect))",
            "lineReferenceRect=\(String(describing: lineReferenceRect))",
            "caretGeometryQuality=\(caretGeometryQuality.rawValue)",
            "observedCharacterWidth=\(String(describing: observedCharacterWidth))"
        ].joined(separator: " ")
    }
}


