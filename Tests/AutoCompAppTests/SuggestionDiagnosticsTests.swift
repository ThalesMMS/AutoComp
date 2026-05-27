import AutoCompCore
@testable import AutoCompApp
import XCTest

final class SuggestionDiagnosticsTests: XCTestCase {
    func testMenuRowsDoNotExposeOutputWhenCollectionIsDisabled() {
        var diagnostics = SuggestionDiagnostics()
        diagnostics.recordBackendSuccess(
            rawText: "secret raw output",
            normalizedText: "secret normalized output",
            collectionAllowed: false,
            route: nil
        )

        let rowValues = diagnostics.menuRows.map(\.value)
        XCTAssertFalse(rowValues.contains { $0.contains("secret") })
        XCTAssertEqual(diagnostics.backend.status, .success)
        XCTAssertNil(diagnostics.output.rawPreview)
        XCTAssertNil(diagnostics.output.normalizedPreview)
    }

    func testBackendFailureUsesActionableLocalizedMessage() {
        var diagnostics = SuggestionDiagnostics()

        diagnostics.recordBackendFailure(RemoteCompletionError.connectivity(.timeout), kind: .remote)

        XCTAssertEqual(
            diagnostics.backend.lastError,
            "Remote backend timed out. Check that the server is reachable and responding quickly."
        )
        XCTAssertEqual(diagnostics.backend.errorTitle(for: .remote), diagnostics.backend.lastError)
        XCTAssertTrue(diagnostics.menuRows.contains {
            $0.title == "Error" && $0.value == diagnostics.backend.lastError
        })
    }

    func testBackendRouteRecordsLastUsedBackendAndFallbackError() {
        var diagnostics = SuggestionDiagnostics()

        diagnostics.recordBackendRequest(policy: CompletionRoutingPolicy(activeKind: .localLlama, fallbackKind: .remote))
        diagnostics.recordBackendSuccess(
            rawText: "raw output",
            normalizedText: "normalized output",
            collectionAllowed: true,
            route: CompletionRoute(
                requestedKind: .localLlama,
                deliveredKind: .remote,
                fallbackErrorDescription: "local model missing"
            )
        )

        XCTAssertEqual(diagnostics.backend.lastUsedTitle, "Remote OpenAI-compatible")
        XCTAssertEqual(diagnostics.backend.requestedKind, .localLlama)
        XCTAssertEqual(diagnostics.backend.deliveredKind, .remote)
        XCTAssertEqual(diagnostics.backend.errorTitle(for: .localLlama), "local model missing")
        XCTAssertEqual(
            diagnostics.menuRows.first(where: { $0.id == "lastBackend" })?.value,
            "Remote OpenAI-compatible"
        )
    }

    func testMenuRowsExposePromptCacheHits() {
        var diagnostics = SuggestionDiagnostics()

        diagnostics.recordPromptCache(
            LlamaPromptCacheStats(
                hits: 3,
                misses: 1,
                resets: 2,
                retainedPromptTokens: 42,
                contextTokens: 512
            )
        )

        XCTAssertEqual(
            diagnostics.menuRows.first(where: { $0.id == "promptCache" })?.value,
            "hits 3, misses 1, resets 2, retained 42/512"
        )
    }

    func testMenuRowsExposeInputMethodSummaryWithoutSourceIdentifier() {
        var diagnostics = SuggestionDiagnostics()

        diagnostics.recordInputMethod(
            InputMethodState(
                isASCIICompatible: false,
                currentInputSourceID: "com.apple.inputmethod.example"
            )
        )

        XCTAssertTrue(diagnostics.menuRows.contains {
            $0.title == "IME" && $0.value == "non-ASCII"
        })
        XCTAssertFalse(diagnostics.menuRows.contains {
            $0.value.contains("com.apple.inputmethod.example")
        })
    }

    func testMenuRowsExposeLowTrustContextSource() {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        var diagnostics = SuggestionDiagnostics()

        diagnostics.recordFocus(
            context: TextContext(
                app: app,
                focusedElementID: "buffer-field",
                textBeforeCursor: "typed",
                captureSources: [.keystrokeBufferLowTrust]
            )
        )

        XCTAssertEqual(diagnostics.focus?.contextSource, "keystrokeBufferLowTrust")
        XCTAssertTrue(diagnostics.menuRows.contains {
            $0.id == "contextSource" && $0.value == "keystrokeBufferLowTrust"
        })
    }

    func testMenuRowsExposeEffectiveCompatibilityProfile() {
        var diagnostics = SuggestionDiagnostics()
        let decision = CompatibilityCatalog().decision(bundleID: "com.tinyspeck.slackmacgap", domain: nil)

        diagnostics.recordCompatibility(decision)

        XCTAssertEqual(diagnostics.compatibility?.bundleID, "com.tinyspeck.slackmacgap")
        XCTAssertEqual(diagnostics.compatibility?.summary, "Slack: Manual only, mirror window, partial")
        XCTAssertEqual(
            diagnostics.menuRows.first(where: { $0.id == "compatibility" })?.value,
            "Slack: Manual only, mirror window, partial"
        )
    }

    func testCompatibilityDiagnosticsMarksSetupRequiredDomainProfile() {
        var diagnostics = SuggestionDiagnostics()
        let decision = CompatibilityCatalog().decision(
            bundleID: "com.google.Chrome",
            domain: "https://docs.google.com/document/d/example"
        )

        diagnostics.recordCompatibility(decision)

        XCTAssertEqual(
            diagnostics.menuRows.first(where: { $0.id == "compatibility" })?.value,
            "Chrome: Automatic, inline, setup needed, setup required"
        )
    }

    func testFocusFailureIsClearedByReadableFocus() {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        var diagnostics = SuggestionDiagnostics()

        diagnostics.recordFocusFailure(AXTextContextError.secureOrUnsupportedField)
        XCTAssertEqual(diagnostics.focusFailure?.status, .blocked)
        XCTAssertEqual(diagnostics.focusFailure?.action, "Secure or unsupported field.")
        XCTAssertEqual(diagnostics.lastDecision?.state, .blocked)
        XCTAssertEqual(diagnostics.lastDecision?.reason, .secureField)

        diagnostics.recordFocus(
            context: TextContext(
                app: app,
                focusedElementID: "field",
                textBeforeCursor: "text"
            )
        )

        XCTAssertNil(diagnostics.focusFailure)
        XCTAssertNil(diagnostics.lastDecision)
        XCTAssertEqual(diagnostics.focus?.appDisplayName, "TextEdit")
    }

    func testLastDecisionRowsCoverPrimaryBlockAndSkipReasons() {
        var diagnostics = SuggestionDiagnostics()

        diagnostics.recordFocusFailure(AXTextContextError.accessibilityNotTrusted)
        XCTAssertEqual(diagnostics.lastDecision?.summary, "blocked: missing-permission")

        diagnostics.recordFocusFailure(AXTextContextError.secureOrUnsupportedField)
        XCTAssertEqual(diagnostics.lastDecision?.summary, "blocked: secure-field")

        diagnostics.recordEligibility(decision(.ineligible(.compatibility), statusMessage: "typed secret"))
        XCTAssertEqual(diagnostics.lastDecision?.summary, "disabled: app-profile")
        XCTAssertFalse(diagnostics.lastDecision?.action.contains("typed secret") == true)

        diagnostics.recordEligibility(decision(.ineligible(.manualOnlyWaitingForTrigger)))
        XCTAssertEqual(diagnostics.lastDecision?.summary, "waiting: manual-trigger-only")

        diagnostics.recordEligibility(decision(.ineligible(.emptyContext), statusMessage: "typed secret"))
        XCTAssertEqual(diagnostics.lastDecision?.summary, "skipped: no-meaningful-prefix")
        XCTAssertFalse(diagnostics.menuRows.contains { $0.value.contains("typed secret") })

        diagnostics.recordEligibility(decision(.ineligible(.inputSourceNonASCII)))
        XCTAssertEqual(diagnostics.lastDecision?.summary, "blocked: ime")

        diagnostics.recordEligibility(decision(.ineligible(.imeCompositionActive)))
        XCTAssertEqual(diagnostics.lastDecision?.summary, "blocked: ime")

        diagnostics.recordEligibility(decision(.ineligible(.selectionActive)))
        XCTAssertEqual(diagnostics.lastDecision?.summary, "waiting: selection-active")

        diagnostics.recordEligibility(decision(.ineligible(.sentenceComplete)))
        XCTAssertEqual(diagnostics.lastDecision?.summary, "skipped: sentence-complete")

        diagnostics.recordEligibility(decision(.ineligible(.unchangedContext)))
        XCTAssertEqual(diagnostics.lastDecision?.summary, "skipped: unchanged-context")

        diagnostics.recordEligibility(decision(.ineligible(.awaitingSpaceTrigger)))
        XCTAssertEqual(diagnostics.lastDecision?.summary, "waiting: waiting-for-space")

        diagnostics.recordBackendPaused(
            BackendStatusSummary(
                state: .paused,
                issue: .timeout,
                suppressUntil: Date(timeIntervalSince1970: 60)
            )
        )
        XCTAssertEqual(diagnostics.lastDecision?.summary, "paused: backend-circuit-breaker")
    }

    func testLastDecisionCanRepresentDiagnosticReasonsWithoutMenuUserText() {
        var diagnostics = SuggestionDiagnostics()

        for reason in SuggestionDiagnostics.LastDecisionReason.allCases {
            diagnostics.recordLastDecision(
                state: .blocked,
                reason: reason,
                action: "typed secret should not be in diagnostic rows"
            )

            XCTAssertEqual(diagnostics.menuRows.first(where: { $0.id == "lastDecision" })?.value, "blocked: \(reason.rawValue)")
            XCTAssertFalse(diagnostics.menuRows.contains { $0.value.contains("typed secret") })
        }
    }

    private func decision(
        _ outcome: SuggestionEligibilityOutcome,
        statusMessage: String? = nil
    ) -> SuggestionEligibilityDecision {
        SuggestionEligibilityDecision(
            outcome: outcome,
            statusMessage: statusMessage,
            logs: []
        )
    }
}
