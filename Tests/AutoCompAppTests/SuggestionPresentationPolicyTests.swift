import AutoCompCore
@testable import AutoCompApp
import XCTest

final class SuggestionPresentationPolicyTests: XCTestCase {
    private let policy = SuggestionPresentationPolicy()

    func testDirectCaretAtEndOfLineResolvesInline() {
        let decision = policy.decision(
            for: suggestion(),
            context: context(caretGeometryQuality: .directCaret),
            requestedDisplayMode: .inline,
            safeOverlayModeEnabled: false,
            capabilities: capabilities(canUseVisualInline: true)
        )

        XCTAssertEqual(decision.mode, .inlineGhostText)
        XCTAssertEqual(decision.tier, .visualInlineOverlay)
        XCTAssertEqual(decision.reason, .trustedCaret)
    }

    func testElementFrameOnlyResolvesCaretPopupWhenAvailable() {
        let decision = policy.decision(
            for: suggestion(),
            context: context(caretGeometryQuality: .elementFrame),
            requestedDisplayMode: .inline,
            safeOverlayModeEnabled: false,
            capabilities: capabilities(canUseVisualInline: true, canUseCaretPopup: true)
        )

        XCTAssertEqual(decision.mode, .caretPopup)
        XCTAssertEqual(decision.tier, .simpleCaretPopup)
        XCTAssertEqual(decision.reason, .weakGeometry)
    }

    func testUnavailableGeometryResolvesMirrorEvenWhenPopupIsAvailable() {
        let decision = policy.decision(
            for: suggestion(),
            context: context(caretRect: nil, caretGeometryQuality: .unavailable),
            requestedDisplayMode: .inline,
            safeOverlayModeEnabled: false,
            capabilities: capabilities(canUseVisualInline: true, canUseCaretPopup: true)
        )

        XCTAssertEqual(decision.mode, .fieldMirror)
        XCTAssertEqual(decision.tier, .mirrorWindow)
        XCTAssertEqual(decision.reason, .weakGeometry)
    }

    func testMidLineVisibleSuffixResolvesCapsule() {
        let decision = policy.decision(
            for: suggestion(),
            context: context(textAfterCursor: "existing text", caretGeometryQuality: .directCaret),
            requestedDisplayMode: .inline,
            safeOverlayModeEnabled: false,
            capabilities: capabilities(canUseVisualInline: true, canUseCaretPopup: true)
        )

        XCTAssertEqual(decision.mode, .capsuleBelowCaret)
        XCTAssertEqual(decision.tier, .simpleCaretPopup)
        XCTAssertEqual(decision.reason, .visibleSuffix)
    }

    func testGoogleDocsResolvesFieldMirrorLikeTextMirror() {
        let decision = policy.decision(
            for: suggestion(),
            context: context(domain: "docs.google.com/document/d/abc", caretGeometryQuality: .directCaret),
            requestedDisplayMode: .inline,
            safeOverlayModeEnabled: false,
            capabilities: capabilities(canUseVisualInline: true, canUseCaretPopup: true)
        )

        XCTAssertEqual(decision.mode, .fieldMirror)
        XCTAssertEqual(decision.tier, .mirrorWindow)
        XCTAssertEqual(decision.reason, .knownJitterHost)
    }

    func testNonDocsKnownJitterHostCanResolveCapsule() {
        let decision = policy.decision(
            for: suggestion(),
            context: context(
                appBundleID: "com.tinyspeck.slackmacgap",
                caretGeometryQuality: .directCaret
            ),
            requestedDisplayMode: .inline,
            safeOverlayModeEnabled: false,
            capabilities: capabilities(canUseVisualInline: true, canUseCaretPopup: true)
        )

        XCTAssertEqual(decision.mode, .capsuleBelowCaret)
        XCTAssertEqual(decision.tier, .simpleCaretPopup)
        XCTAssertEqual(decision.reason, .knownJitterHost)
    }

    func testSuffixStartingWithNewlineAllowsInline() {
        let decision = policy.decision(
            for: suggestion(),
            context: context(textAfterCursor: "\nnext paragraph", caretGeometryQuality: .directCaret),
            requestedDisplayMode: .inline,
            safeOverlayModeEnabled: false,
            capabilities: capabilities(canUseVisualInline: true, canUseCaretPopup: true)
        )

        XCTAssertEqual(decision.mode, .inlineGhostText)
        XCTAssertEqual(decision.tier, .visualInlineOverlay)
        XCTAssertEqual(decision.reason, .trustedCaret)
    }

    func testCompatibilityMirrorModeForcesFieldMirror() {
        let decision = policy.decision(
            for: suggestion(),
            context: context(caretGeometryQuality: .directCaret),
            requestedDisplayMode: .mirrorWindow,
            safeOverlayModeEnabled: false,
            capabilities: capabilities(canUseVisualInline: true, canUseCaretPopup: true)
        )

        XCTAssertEqual(decision.mode, .fieldMirror)
        XCTAssertEqual(decision.tier, .mirrorWindow)
        XCTAssertEqual(decision.reason, .compatibilityMirrorMode)
    }

    func testCompatibilityMirrorModeWinsOverSafeOverlayMode() {
        let decision = policy.decision(
            for: suggestion(),
            context: context(caretGeometryQuality: .directCaret),
            requestedDisplayMode: .mirrorWindow,
            safeOverlayModeEnabled: true,
            capabilities: capabilities(canUseVisualInline: true, canUseCaretPopup: true)
        )

        XCTAssertEqual(decision.mode, .fieldMirror)
        XCTAssertEqual(decision.tier, .mirrorWindow)
        XCTAssertEqual(decision.reason, .compatibilityMirrorMode)
    }

    func testSafeOverlayModeForcesSafePopupWhenAvailable() {
        let decision = policy.decision(
            for: suggestion(),
            context: context(caretGeometryQuality: .directCaret),
            requestedDisplayMode: .inline,
            safeOverlayModeEnabled: true,
            capabilities: capabilities(canUseVisualInline: true, canUseCaretPopup: true)
        )

        XCTAssertEqual(decision.mode, .caretPopup)
        XCTAssertEqual(decision.tier, .simpleCaretPopup)
        XCTAssertEqual(decision.reason, .safeOverlayMode)
    }

    func testDisabledCompatibilityResolvesDisabled() {
        let decision = policy.decision(
            for: suggestion(),
            context: context(caretGeometryQuality: .directCaret),
            requestedDisplayMode: .disabled,
            safeOverlayModeEnabled: false,
            capabilities: capabilities(canUseVisualInline: true, canUseCaretPopup: true)
        )

        XCTAssertEqual(decision.mode, .disabled)
        XCTAssertEqual(decision.tier, .disabled)
        XCTAssertEqual(decision.reason, .disabledByCompatibility)
    }

    private func suggestion() -> Suggestion {
        Suggestion(baseContextID: UUID(), visibleText: " completion", latencyMs: 12)
    }

    private func context(
        appBundleID: String = "com.apple.TextEdit",
        domain: String? = nil,
        textAfterCursor: String? = nil,
        caretRect: CGRect? = CGRect(x: 100, y: 100, width: 2, height: 20),
        caretGeometryQuality: CaretGeometryQuality
    ) -> TextContext {
        TextContext(
            app: AppIdentity(bundleID: appBundleID, displayName: "TextEdit", processID: 1),
            domain: domain,
            focusedElementID: "field",
            textBeforeCursor: "Hello",
            textAfterCursor: textAfterCursor,
            selectedRange: NSRange(location: 5, length: 0),
            caretRect: caretRect,
            focusedElementRect: CGRect(x: 60, y: 90, width: 500, height: 40),
            caretGeometryQuality: caretGeometryQuality
        )
    }

    private func capabilities(
        canUseNativeInline: Bool = false,
        canUseVisualInline: Bool = false,
        canUseCaretPopup: Bool = false,
        canUseMultiSuggestionPopup: Bool = false
    ) -> SuggestionPresentationPolicy.Capabilities {
        SuggestionPresentationPolicy.Capabilities(
            canUseNativeInline: canUseNativeInline,
            canUseVisualInline: canUseVisualInline,
            canUseCaretPopup: canUseCaretPopup,
            canUseMultiSuggestionPopup: canUseMultiSuggestionPopup
        )
    }
}
