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

    func testMenuRowsExposeOnlyRedactedOutputSummariesWhenCollectionIsEnabled() {
        let rawText = "SECRET raw output"
        let normalizedText = "SECRET normalized output"
        var diagnostics = SuggestionDiagnostics()

        diagnostics.recordBackendSuccess(
            rawText: rawText,
            normalizedText: normalizedText,
            collectionAllowed: true,
            route: nil
        )

        let rowValues = diagnostics.menuRows.map(\.value)
        XCTAssertEqual(diagnostics.output.rawPreview, AutoCompLogger.redactedSummary(for: rawText).description)
        XCTAssertEqual(diagnostics.output.normalizedPreview, AutoCompLogger.redactedSummary(for: normalizedText).description)
        XCTAssertTrue(rowValues.contains(AutoCompLogger.redactedSummary(for: rawText).description))
        XCTAssertTrue(rowValues.contains(AutoCompLogger.redactedSummary(for: normalizedText).description))
        XCTAssertFalse(rowValues.contains { $0.contains("SECRET") })
        XCTAssertFalse(rowValues.contains { $0.contains("raw output") })
        XCTAssertFalse(rowValues.contains { $0.contains("normalized output") })
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

    func testMenuRowsExposeLatencyStagesAndRedactedReport() throws {
        var diagnostics = SuggestionDiagnostics()

        diagnostics.recordLatency(CompletionLatencyReport(
            axCaptureMs: 3,
            geometryMs: nil,
            visualContextMs: 5,
            clipboardFilterMs: 1,
            debounceMs: 250,
            backendMs: 40,
            normalizationMs: 2,
            overlayMs: 4,
            totalMs: 312
        ))

        XCTAssertEqual(
            diagnostics.menuRows.first(where: { $0.id == "latency.axCaptureMs" })?.value,
            "3 ms"
        )
        XCTAssertEqual(
            diagnostics.menuRows.first(where: { $0.id == "latency.geometryMs" })?.value,
            "not measured"
        )
        XCTAssertEqual(
            diagnostics.menuRows.first(where: { $0.id == "latency.totalMs" })?.value,
            "312 ms"
        )
        let redactedReport = try XCTUnwrap(diagnostics.redactedLatencyReport())
        XCTAssertTrue(redactedReport.contains("backendMs=40"))
        XCTAssertFalse(redactedReport.contains("typed secret"))
        XCTAssertFalse(redactedReport.contains("prompt text"))
        XCTAssertFalse(redactedReport.contains("clipboard text"))
        XCTAssertFalse(redactedReport.contains("com.apple.TextEdit"))
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

    func testMenuRowsExposeLowTrustContextSourceAndQualityWithoutContent() {
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

        XCTAssertEqual(diagnostics.focus?.contextSource, "Keystroke buffer")
        XCTAssertEqual(diagnostics.focus?.geometryQuality, "unavailable")
        XCTAssertEqual(diagnostics.focus?.contextTrust, "low-trust")
        XCTAssertEqual(
            diagnostics.focus?.contextWarning,
            "Low-trust fallback: visual and clipboard context isolated."
        )
        XCTAssertTrue(diagnostics.menuRows.contains {
            $0.id == "contextSource" && $0.value == "Keystroke buffer"
        })
        XCTAssertTrue(diagnostics.menuRows.contains {
            $0.id == "geometry" && $0.value == "unavailable"
        })
        XCTAssertTrue(diagnostics.menuRows.contains {
            $0.id == "contextTrust" && $0.value == "low-trust"
        })
        XCTAssertTrue(diagnostics.menuRows.contains {
            $0.id == "contextWarning"
                && $0.value == "Low-trust fallback: visual and clipboard context isolated."
        })
        XCTAssertFalse(diagnostics.menuRows.contains { $0.value.contains("typed") })
    }

    func testMenuRowsUseNonContentCaptureLabelsForMixedSourceAndGeometryQuality() {
        let app = AppIdentity(bundleID: "com.google.Chrome", displayName: "Chrome", processID: 1)
        var diagnostics = SuggestionDiagnostics()

        diagnostics.recordFocus(
            context: TextContext(
                app: app,
                focusedElementID: "docs-field",
                textBeforeCursor: "private draft",
                caretGeometryQuality: .screenOCR,
                captureSources: [.accessibility, .screenOCR]
            )
        )

        XCTAssertEqual(diagnostics.focus?.contextSource, "Accessibility, OCR geometry")
        XCTAssertEqual(diagnostics.focus?.geometryQuality, "OCR")
        XCTAssertEqual(diagnostics.focus?.contextTrust, "standard")
        XCTAssertNil(diagnostics.focus?.contextWarning)
        XCTAssertFalse(diagnostics.menuRows.contains { $0.value.contains("private draft") })
    }

    func testContextCaptureDiagnosticsSeparatesVisualOCRAndClipboardFromFocusedText() {
        let app = AppIdentity(bundleID: "com.google.Chrome", displayName: "Chrome", processID: 1)
        let diagnostics = ContextCaptureDiagnostics(
            context: TextContext(
                app: app,
                focusedElementID: "field",
                textBeforeCursor: "private draft",
                caretGeometryQuality: .glyph,
                captureSources: [.accessibility]
            ),
            visualContext: VisualContextSnapshot(summary: "private visual text"),
            clipboardContext: ClipboardContextSnapshot(
                summary: "private clipboard text",
                status: .included,
                captureSources: [.clipboard]
            )
        )

        XCTAssertEqual(diagnostics.contextSourceTitle, "Accessibility")
        XCTAssertEqual(diagnostics.geometryQualityTitle, "glyph")
        XCTAssertEqual(diagnostics.supplementalSourceTitle, "Visual OCR, Clipboard")
        XCTAssertEqual(diagnostics.supplementalSourceLogValue, "visual-ocr,clipboard")
        XCTAssertEqual(diagnostics.visualContextLogValue, "included")
        XCTAssertEqual(diagnostics.clipboardContextLogValue, "included")
        XCTAssertFalse(diagnostics.supplementalSourceTitle.contains("private"))
        XCTAssertFalse(diagnostics.supplementalSourceLogValue.contains("private"))
    }

    func testMenuRowsExposeSupplementalContextSourcesWithoutContent() {
        let app = AppIdentity(bundleID: "com.google.Chrome", displayName: "Chrome", processID: 1)
        var diagnostics = SuggestionDiagnostics()
        let context = TextContext(
            app: app,
            focusedElementID: "field",
            textBeforeCursor: "private draft",
            caretGeometryQuality: .directCaret,
            captureSources: [.accessibility]
        )

        diagnostics.recordFocus(context: context)
        diagnostics.recordSupplementalContext(
            context: context,
            visualContext: VisualContextSnapshot(summary: "private visual text"),
            clipboardContext: ClipboardContextSnapshot(
                summary: "private clipboard text",
                status: .included,
                captureSources: [.clipboard]
            )
        )

        XCTAssertEqual(
            diagnostics.menuRows.first(where: { $0.id == "supplementalContext" })?.value,
            "Visual OCR, Clipboard"
        )
        XCTAssertEqual(
            diagnostics.menuRows.first(where: { $0.id == "visualContext" })?.value,
            "included"
        )
        XCTAssertEqual(
            diagnostics.menuRows.first(where: { $0.id == "clipboardContext" })?.value,
            "included"
        )
        XCTAssertFalse(diagnostics.menuRows.contains { $0.value.contains("private") })
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
        XCTAssertEqual(
            diagnostics.menuRows.first(where: { $0.id == "compatibilityRuleSource" })?.value,
            "default"
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

    func testMenuRowsExposeDomainResolutionRuleSourcesPrivacyAndBackendDestination() {
        let app = AppIdentity(bundleID: "com.google.Chrome", displayName: "Chrome", processID: 1)
        var diagnostics = SuggestionDiagnostics()
        let compatibility = CompatibilityCatalog().decision(
            bundleID: app.bundleID,
            domain: nil,
            userModeOverrides: ["com.google.Chrome": .manualOnly]
        )

        diagnostics.recordFocus(
            context: TextContext(
                app: app,
                domain: nil,
                focusedElementID: "field",
                textBeforeCursor: "typed secret"
            ),
            domainResolution: BrowserDomainResolution(
                status: .unavailableAppleEventsDenied,
                domain: nil
            )
        )
        diagnostics.recordCompatibility(compatibility)
        diagnostics.recordPrivacy(PrivacyCollectionDecision(allowed: true, ruleSource: .appRule))
        diagnostics.recordBackendRequest(policy: CompletionRoutingPolicy(activeKind: .remote, fallbackKind: nil))

        XCTAssertEqual(
            diagnostics.menuRows.first(where: { $0.id == "domain" })?.value,
            "unavailable-appleevents-denied"
        )
        XCTAssertEqual(
            diagnostics.menuRows.first(where: { $0.id == "compatibilityRuleSource" })?.value,
            "app-rule"
        )
        XCTAssertEqual(
            diagnostics.menuRows.first(where: { $0.id == "privacy" })?.value,
            "collection allowed, app-rule"
        )
        XCTAssertEqual(
            diagnostics.menuRows.first(where: { $0.id == "backendDestination" })?.value,
            "Remote OpenAI-compatible"
        )
        XCTAssertFalse(diagnostics.menuRows.contains { $0.value.contains("typed secret") })
        XCTAssertFalse(diagnostics.menuRows.contains { $0.value.contains("https://") })
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

        diagnostics.recordRiskyHostAppBlock(action: "typed secret")
        XCTAssertEqual(diagnostics.lastDecision?.summary, "blocked: blocked-risky-host-app")
        XCTAssertFalse(diagnostics.menuRows.contains { $0.value.contains("typed secret") })
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
