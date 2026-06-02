import AutoCompCore
import Foundation

enum SuggestionPresentationMode: String, Equatable, Sendable {
    case inlineGhostText = "inline-ghost-text"
    case caretPopup = "caret-popup"
    case fieldMirror = "field-mirror"
    case capsuleBelowCaret = "capsule-below-caret"
    case multiSuggestionPopup = "multi-suggestion-popup"
    case disabled
}

struct SuggestionPresentationPolicy: Sendable {
    struct Capabilities: Equatable, Sendable {
        let canUseNativeInline: Bool
        let canUseVisualInline: Bool
        let canUseCaretPopup: Bool
        let canUseMultiSuggestionPopup: Bool

        init(
            canUseNativeInline: Bool,
            canUseVisualInline: Bool,
            canUseCaretPopup: Bool,
            canUseMultiSuggestionPopup: Bool
        ) {
            self.canUseNativeInline = canUseNativeInline
            self.canUseVisualInline = canUseVisualInline
            self.canUseCaretPopup = canUseCaretPopup
            self.canUseMultiSuggestionPopup = canUseMultiSuggestionPopup
        }
    }

    struct Decision: Equatable, Sendable {
        let mode: SuggestionPresentationMode
        let tier: PreviewPresentationTier
        let reason: Reason
    }

    enum Reason: String, Equatable, Sendable {
        case disabledByCompatibility = "disabled-by-compatibility"
        case emptySuggestion = "empty-suggestion"
        case safeOverlayMode = "safe-overlay-mode"
        case multipleSuggestions = "multiple-suggestions"
        case compatibilityMirrorMode = "compatibility-mirror-mode"
        case visibleSuffix = "visible-suffix"
        case selectionReplacement = "selection-replacement"
        case trustedCaret = "trusted-caret"
        case weakGeometry = "weak-geometry"
        case inlineUnavailable = "inline-unavailable"
        case knownJitterHost = "known-jitter-host"
    }

    private let trustEvaluator: CaretGeometryTrustEvaluator

    init(trustEvaluator: CaretGeometryTrustEvaluator = .default) {
        self.trustEvaluator = trustEvaluator
    }

    func decision(
        for suggestion: Suggestion,
        context: TextContext,
        requestedDisplayMode: SuggestionDisplayMode,
        safeOverlayModeEnabled: Bool,
        capabilities: Capabilities
    ) -> Decision {
        guard requestedDisplayMode != .disabled else {
            return Decision(mode: .disabled, tier: .disabled, reason: .disabledByCompatibility)
        }

        guard !suggestion.visibleText.isEmpty else {
            return Decision(mode: .disabled, tier: .disabled, reason: .emptySuggestion)
        }

        if isGoogleDocs(context) {
            return Decision(mode: .fieldMirror, tier: .mirrorWindow, reason: .knownJitterHost)
        }

        if safeOverlayModeEnabled {
            if requestedDisplayMode == .mirrorWindow {
                return Decision(mode: .fieldMirror, tier: .mirrorWindow, reason: .compatibilityMirrorMode)
            }
            return safeModeDecision(capabilities: capabilities)
        }

        if suggestion.hasMultipleAlternatives,
           capabilities.canUseMultiSuggestionPopup {
            return Decision(mode: .multiSuggestionPopup, tier: .multiSuggestionPopup, reason: .multipleSuggestions)
        }

        if requestedDisplayMode == .mirrorWindow {
            return Decision(mode: .fieldMirror, tier: .mirrorWindow, reason: .compatibilityMirrorMode)
        }

        if hasSelection(context) {
            return capsuleOrMirror(reason: .selectionReplacement, capabilities: capabilities)
        }

        if hasVisibleSameLineSuffix(context.textAfterCursor) {
            return capsuleOrMirror(reason: .visibleSuffix, capabilities: capabilities)
        }

        if isKnownJitterHost(context) {
            return capsuleOrMirror(reason: .knownJitterHost, capabilities: capabilities)
        }

        let safety = trustEvaluator.evaluate(
            caretRect: context.caretRect,
            focusedElementRect: context.focusedElementRect,
            screenBounds: nil,
            quality: context.caretGeometryQuality
        )

        switch safety {
        case .allowInline:
            if capabilities.canUseNativeInline {
                return Decision(mode: .inlineGhostText, tier: .nativeInline, reason: .trustedCaret)
            }
            if capabilities.canUseVisualInline {
                return Decision(mode: .inlineGhostText, tier: .visualInlineOverlay, reason: .trustedCaret)
            }
            return popupOrMirror(reason: .inlineUnavailable, capabilities: capabilities)
        case .forcePopup:
            return popupOrMirror(reason: .weakGeometry, capabilities: capabilities)
        case .suppress:
            return Decision(mode: .fieldMirror, tier: .mirrorWindow, reason: .weakGeometry)
        }
    }

    private func safeModeDecision(capabilities: Capabilities) -> Decision {
        if capabilities.canUseCaretPopup {
            return Decision(mode: .caretPopup, tier: .simpleCaretPopup, reason: .safeOverlayMode)
        }
        return Decision(mode: .fieldMirror, tier: .mirrorWindow, reason: .safeOverlayMode)
    }

    private func capsuleOrMirror(
        reason: Reason,
        capabilities: Capabilities
    ) -> Decision {
        if capabilities.canUseCaretPopup {
            return Decision(mode: .capsuleBelowCaret, tier: .simpleCaretPopup, reason: reason)
        }
        return Decision(mode: .fieldMirror, tier: .mirrorWindow, reason: reason)
    }

    private func popupOrMirror(
        reason: Reason,
        capabilities: Capabilities
    ) -> Decision {
        if capabilities.canUseCaretPopup {
            return Decision(mode: .caretPopup, tier: .simpleCaretPopup, reason: reason)
        }
        return Decision(mode: .fieldMirror, tier: .mirrorWindow, reason: reason)
    }

    private func hasSelection(_ context: TextContext) -> Bool {
        if let selectedText = context.selectedText,
           !selectedText.isEmpty {
            return true
        }
        return (context.selectedRange?.length ?? 0) > 0
    }

    private func hasVisibleSameLineSuffix(_ suffix: String?) -> Bool {
        guard let suffix,
              let firstScalar = suffix.unicodeScalars.first,
              !CharacterSet.newlines.contains(firstScalar) else {
            return false
        }

        return suffix.unicodeScalars.contains {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
    }

    private func isKnownJitterHost(_ context: TextContext) -> Bool {
        if isGoogleDocs(context) {
            return true
        }

        return [
            "com.tinyspeck.slackmacgap",
            "com.hnc.Discord"
        ].contains(context.app.bundleID)
    }

    private func isGoogleDocs(_ context: TextContext) -> Bool {
        context.domain?.contains("docs.google.com") == true
    }
}
