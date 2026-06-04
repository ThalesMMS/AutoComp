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
    private let stabilityGate: SuggestionOverlayStabilityGate
    private let presentationPolicy: SuggestionPresentationPolicy
    private let now: () -> Date
    private var lastPresentationSnapshot: SuggestionOverlayStabilityGate.Snapshot?
    private var lastAcceptedPresentationAt: Date?

    private(set) var activeTier: PreviewPresentationTier = .disabled

    init(
        safeOverlayModeEnabled: Bool = SafeOverlayMode.isEnabled,
        overlayRecoveryAdvisor: OverlayRecoveryAdvisor? = nil,
        focusDebugOverlayPresenter: FocusDebugOverlayPresenting? = nil,
        stabilityGate: SuggestionOverlayStabilityGate = SuggestionOverlayStabilityGate(),
        presentationPolicy: SuggestionPresentationPolicy = SuggestionPresentationPolicy(),
        now: @escaping () -> Date = Date.init
    ) {
        let shortcutSettingsStore = KeyboardShortcutSettingsStore()
        let hintsProvider = OverlayShortcutHintsProvider()

        self.nativeInlinePresenter = SystemNativeInlineFallbackPresenter()
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
        self.stabilityGate = stabilityGate
        self.presentationPolicy = presentationPolicy
        self.now = now
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
        overlayRecoveryAdvisor: OverlayRecoveryAdvisor? = nil,
        stabilityGate: SuggestionOverlayStabilityGate = SuggestionOverlayStabilityGate(),
        presentationPolicy: SuggestionPresentationPolicy = SuggestionPresentationPolicy(),
        now: @escaping () -> Date = Date.init
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
        self.stabilityGate = stabilityGate
        self.presentationPolicy = presentationPolicy
        self.now = now
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
        lastPresentationSnapshot = nil
        lastAcceptedPresentationAt = nil
        nativeInlinePresenter.hide()
        multiSuggestionPopupPresenter.hide()
        visualInlinePresenter.hide()
        simpleCaretPopupPresenter.hide()
        mirrorWindowPresenter.hide()
        activationIndicator.hide()
        focusDebugOverlayPresenter.hide()
    }

    func resolveTier(for suggestion: Suggestion, context: TextContext, mode: SuggestionDisplayMode) -> PreviewPresentationTier {
        resolvePresentation(for: suggestion, context: context, mode: mode).tier
    }

    private func present(_ suggestion: Suggestion, for context: TextContext, mode: SuggestionDisplayMode, isUpdate: Bool) {
        let presentationDecision = resolvePresentation(for: suggestion, context: context, mode: mode)
        let nextTier = presentationDecision.tier
        if safeOverlayModeEnabled {
            GeometryDebug.log("safe-overlay-mode active feature=preview-tier mode=\(mode.rawValue) resolvedTier=\(nextTier)")
        }
        GeometryDebug.log("presentation-policy mode=\(presentationDecision.mode.rawValue) reason=\(presentationDecision.reason.rawValue) requestedMode=\(mode.rawValue) resolvedTier=\(nextTier)")
        GeometryDebug.log("presenter-present update=\(isUpdate) previousTier=\(String(describing: activeTier)) mode=\(mode.rawValue) resolvedTier=\(nextTier) app=\(context.app.displayName) bundle=\(context.app.bundleID) visibleLength=\((suggestion.visibleText as NSString).length) context=\(context.geometryDebugDescription)")
        let proposedSnapshot = SuggestionOverlayStabilityGate.Snapshot(
            suggestion: suggestion,
            context: context,
            displayMode: mode,
            presentationTier: nextTier
        )
        let currentDate = now()
        if isUpdate {
            let decision = stabilityGate.decision(
                previous: lastPresentationSnapshot,
                proposed: proposedSnapshot,
                now: currentDate,
                lastAcceptanceAt: lastAcceptedPresentationAt
            )
            GeometryDebug.log("overlay-stability decision=\(decision.diagnosticName) reason=\(decision.reason.rawValue) tier=\(nextTier)")
            guard decision.shouldPresent else {
                return
            }
        }

        recordOverlayRecoverySignal(tier: nextTier, mode: mode)
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
        recordPresentedSnapshot(proposedSnapshot, now: currentDate)
    }

    private func resolvePresentation(
        for suggestion: Suggestion,
        context: TextContext,
        mode: SuggestionDisplayMode
    ) -> SuggestionPresentationPolicy.Decision {
        let nativeInlineAvailability = nativeInlinePresenter.availability(
            for: suggestion,
            context: context
        )
        let decision = presentationPolicy.decision(
            for: suggestion,
            context: context,
            requestedDisplayMode: mode,
            safeOverlayModeEnabled: safeOverlayModeEnabled,
            capabilities: SuggestionPresentationPolicy.Capabilities(
                canUseNativeInline: nativeInlineAvailability.canPresent,
                canUseVisualInline: visualInlinePresenter.canPresent(suggestion, for: context),
                canUseCaretPopup: simpleCaretPopupPresenter.canPresent(suggestion, for: context),
                canUseMultiSuggestionPopup: multiSuggestionPopupPresenter.canPresent(suggestion, for: context)
            )
        )
        if mode == .inline,
           !nativeInlineAvailability.canPresent {
            GeometryDebug.log("native-inline fallback reason=\(nativeInlineAvailability.diagnosticReason ?? "unreported") resolvedTier=\(decision.tier)")
        }
        return decision
    }

    private func recordPresentedSnapshot(
        _ snapshot: SuggestionOverlayStabilityGate.Snapshot,
        now: Date
    ) {
        if !snapshot.acceptedPrefix.isEmpty,
           snapshot.acceptedPrefix != lastPresentationSnapshot?.acceptedPrefix {
            lastAcceptedPresentationAt = now
        }
        lastPresentationSnapshot = snapshot
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
