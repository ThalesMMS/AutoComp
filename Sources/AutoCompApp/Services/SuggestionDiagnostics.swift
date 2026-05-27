import AutoCompCore
import Foundation

enum SuggestionBackendDiagnosticStatus: String, Equatable, Sendable {
    case idle = "idle"
    case requested = "requested"
    case success = "success"
    case failed = "failed"
    case discarded = "discarded"
}

struct SuggestionDiagnosticRow: Identifiable, Equatable {
    let id: String
    let title: String
    let value: String
}

struct SuggestionDiagnostics: Equatable {
    struct Focus: Equatable {
        let appDisplayName: String
        let bundleID: String
        let domain: String?
        let focusedElementID: String?
        let contextSource: String
        let geometryQuality: String
        let hasCaretRect: Bool
        let hasFocusedElementRect: Bool
    }

    enum FocusFailureStatus: String, Equatable, Sendable {
        case unsupported = "Unsupported"
        case blocked = "Blocked"
    }

    struct FocusFailure: Equatable {
        let status: FocusFailureStatus
        let action: String
    }

    enum LastDecisionState: String, Equatable, Sendable {
        case blocked
        case disabled
        case waiting
        case paused
        case skipped
        case ready
    }

    enum LastDecisionReason: String, CaseIterable, Equatable, Sendable {
        case missingPermission = "missing-permission"
        case appProfile = "app-profile"
        case manualTriggerOnly = "manual-trigger-only"
        case secureField = "secure-field"
        case selectionActive = "selection-active"
        case poorGeometry = "poor-geometry"
        case backendCircuitBreaker = "backend-circuit-breaker"
        case ime = "ime"
        case privacyDomainDisabled = "privacy-domain-disabled"
        case noMeaningfulPrefix = "no-meaningful-prefix"
        case sentenceComplete = "sentence-complete"
        case unchangedContext = "unchanged-context"
        case waitingForSpace = "waiting-for-space"
        case backendError = "backend-error"
        case eligible = "eligible"
    }

    struct LastDecision: Equatable {
        let state: LastDecisionState
        let reason: LastDecisionReason
        let action: String

        var summary: String {
            "\(state.rawValue): \(reason.rawValue)"
        }
    }

    struct Eligibility: Equatable {
        let outcome: String
        let skipReason: String?
        let statusMessage: String?
    }

    struct Compatibility: Equatable {
        let appDisplayName: String
        let bundleID: String
        let activationMode: String
        let displayMode: String
        let status: String
        let setupRequired: Bool

        var summary: String {
            var parts = [
                "\(appDisplayName): \(activationMode)",
                displayMode,
                status
            ]
            if setupRequired {
                parts.append("setup required")
            }
            return parts.joined(separator: ", ")
        }
    }

    struct InputMethod: Equatable {
        let summary: String
        let inputSourceID: String?
    }

    struct Backend: Equatable {
        let status: SuggestionBackendDiagnosticStatus
        let lastError: String?
        let requestedKind: CompletionEngineKind?
        let deliveredKind: CompletionEngineKind?
        let localLastError: String?
        let appleLastError: String?
        let remoteLastError: String?

        init(
            status: SuggestionBackendDiagnosticStatus,
            lastError: String?,
            requestedKind: CompletionEngineKind? = nil,
            deliveredKind: CompletionEngineKind? = nil,
            localLastError: String? = nil,
            appleLastError: String? = nil,
            remoteLastError: String? = nil
        ) {
            self.status = status
            self.lastError = lastError
            self.requestedKind = requestedKind
            self.deliveredKind = deliveredKind
            self.localLastError = localLastError
            self.appleLastError = appleLastError
            self.remoteLastError = remoteLastError
        }

        var lastUsedTitle: String {
            deliveredKind?.displayName ?? "None yet"
        }

        func errorTitle(for kind: CompletionEngineKind, storedLocalError: String? = nil) -> String {
            let error: String?
            switch kind {
            case .remote:
                error = remoteLastError
            case .localLlama:
                error = localLastError ?? storedLocalError
            case .appleIntelligence:
                error = appleLastError
            }
            guard let error, !error.isEmpty else {
                return "None"
            }
            return error
        }

        func preservingState(
            status: SuggestionBackendDiagnosticStatus,
            lastError: String?,
            requestedKind: CompletionEngineKind? = nil,
            deliveredKind: CompletionEngineKind? = nil
        ) -> Backend {
            Backend(
                status: status,
                lastError: lastError,
                requestedKind: requestedKind ?? self.requestedKind,
                deliveredKind: deliveredKind ?? self.deliveredKind,
                localLastError: localLastError,
                appleLastError: appleLastError,
                remoteLastError: remoteLastError
            )
        }

        func recordingError(_ error: String, for kind: CompletionEngineKind?) -> Backend {
            Backend(
                status: status,
                lastError: lastError,
                requestedKind: requestedKind,
                deliveredKind: deliveredKind,
                localLastError: kind == .localLlama ? error : localLastError,
                appleLastError: kind == .appleIntelligence ? error : appleLastError,
                remoteLastError: kind == .remote ? error : remoteLastError
            )
        }
    }

    struct PromptCache: Equatable {
        let hits: UInt64
        let misses: UInt64
        let resets: UInt64
        let retainedPromptTokens: Int
        let contextTokens: UInt32

        var summary: String {
            "hits \(hits), misses \(misses), resets \(resets), retained \(retainedPromptTokens)/\(contextTokens)"
        }
    }

    struct Output: Equatable {
        let rawPreview: String?
        let normalizedPreview: String?
    }

    var focus: Focus?
    var focusFailure: FocusFailure?
    var lastDecision: LastDecision?
    var eligibility: Eligibility?
    var compatibility: Compatibility?
    var inputMethod = InputMethod(summary: InputMethodState.asciiCompatible.diagnosticSummary, inputSourceID: nil)
    var backend = Backend(status: .idle, lastError: nil)
    var promptCache: PromptCache?
    var staleDiscardReason: String?
    var output = Output(rawPreview: nil, normalizedPreview: nil)

    var menuRows: [SuggestionDiagnosticRow] {
        var rows: [SuggestionDiagnosticRow] = []
        if let focus {
            rows.append(SuggestionDiagnosticRow(id: "focus", title: "Focus", value: focus.appDisplayName))
            rows.append(SuggestionDiagnosticRow(id: "contextSource", title: "Context Source", value: focus.contextSource))
            rows.append(SuggestionDiagnosticRow(id: "geometry", title: "Geometry", value: focus.geometryQuality))
            if let domain = focus.domain {
                rows.append(SuggestionDiagnosticRow(id: "domain", title: "Domain", value: domain))
            }
        }
        if let compatibility {
            rows.append(SuggestionDiagnosticRow(id: "compatibility", title: "Compatibility", value: compatibility.summary))
        }
        if let eligibility {
            let value = eligibility.skipReason ?? eligibility.outcome
            rows.append(SuggestionDiagnosticRow(id: "eligibility", title: "Eligibility", value: value))
        }
        if let lastDecision {
            rows.append(SuggestionDiagnosticRow(id: "lastDecision", title: "Last decision", value: lastDecision.summary))
        }
        rows.append(SuggestionDiagnosticRow(id: "ime", title: "IME", value: inputMethod.summary))
        rows.append(SuggestionDiagnosticRow(id: "backend", title: "Backend", value: backend.status.rawValue))
        rows.append(SuggestionDiagnosticRow(id: "lastBackend", title: "Last backend", value: backend.lastUsedTitle))
        if let promptCache {
            rows.append(SuggestionDiagnosticRow(id: "promptCache", title: "Prompt Cache", value: promptCache.summary))
        }
        if let staleDiscardReason {
            rows.append(SuggestionDiagnosticRow(id: "stale", title: "Discard", value: staleDiscardReason))
        }
        if let normalizedPreview = output.normalizedPreview {
            rows.append(SuggestionDiagnosticRow(id: "normalized", title: "Normalized", value: normalizedPreview))
        }
        if let rawPreview = output.rawPreview {
            rows.append(SuggestionDiagnosticRow(id: "raw", title: "Raw", value: rawPreview))
        }
        if let error = backend.lastError {
            rows.append(SuggestionDiagnosticRow(id: "error", title: "Error", value: error))
        }
        return rows
    }

    mutating func recordFocus(context: TextContext) {
        if focusFailure != nil {
            lastDecision = nil
        }
        focusFailure = nil
        focus = Focus(
            appDisplayName: context.app.displayName,
            bundleID: context.app.bundleID,
            domain: context.domain,
            focusedElementID: context.focusedElementID,
            contextSource: context.captureSources
                .map(\.rawValue)
                .sorted()
                .joined(separator: ","),
            geometryQuality: context.caretGeometryQuality.rawValue,
            hasCaretRect: context.caretRect != nil,
            hasFocusedElementRect: context.focusedElementRect != nil
        )
    }

    mutating func recordFocusFailure(_ error: Error) {
        guard let contextError = error as? AXTextContextError else {
            focusFailure = FocusFailure(
                status: .unsupported,
                action: "Focus a supported text field."
            )
            recordLastDecision(
                state: .blocked,
                reason: .poorGeometry,
                action: "Focus a supported text field."
            )
            return
        }

        switch contextError {
        case .accessibilityNotTrusted:
            focusFailure = FocusFailure(
                status: .blocked,
                action: "Enable Accessibility permission."
            )
            recordLastDecision(
                state: .blocked,
                reason: .missingPermission,
                action: "Enable Accessibility permission."
            )
        case .noFrontmostApplication:
            focusFailure = FocusFailure(
                status: .unsupported,
                action: "Select an app with a text field."
            )
            recordLastDecision(
                state: .blocked,
                reason: .poorGeometry,
                action: "Select an app with a text field."
            )
        case .noFocusedElement:
            focusFailure = FocusFailure(
                status: .unsupported,
                action: "Focus a supported text field."
            )
            recordLastDecision(
                state: .blocked,
                reason: .poorGeometry,
                action: "Focus a supported text field."
            )
        case .secureOrUnsupportedField:
            focusFailure = FocusFailure(
                status: .blocked,
                action: "Secure or unsupported field."
            )
            recordLastDecision(
                state: .blocked,
                reason: .secureField,
                action: "Secure or unsupported field."
            )
        case .noReadableText:
            focusFailure = FocusFailure(
                status: .unsupported,
                action: "Focused field did not expose readable text."
            )
            recordLastDecision(
                state: .blocked,
                reason: .poorGeometry,
                action: "Focused field did not expose readable text."
            )
        }
    }

    mutating func recordInputMethod(_ state: InputMethodState) {
        inputMethod = InputMethod(
            summary: state.diagnosticSummary,
            inputSourceID: state.currentInputSourceID
        )
    }

    mutating func recordEligibility(_ decision: SuggestionEligibilityDecision) {
        let outcome: String
        let skipReason: String?
        switch decision.outcome {
        case .eligible:
            outcome = "eligible"
            skipReason = nil
        case .ineligible(let reason):
            outcome = "ineligible"
            skipReason = reason.rawValue
        }

        eligibility = Eligibility(
            outcome: outcome,
            skipReason: skipReason,
            statusMessage: decision.statusMessage
        )
        recordLastDecision(for: decision)
    }

    mutating func recordCompatibility(_ decision: CompatibilityDecision) {
        compatibility = Compatibility(
            appDisplayName: decision.profile.displayName,
            bundleID: decision.profile.bundleID,
            activationMode: decision.overrideMode.title,
            displayMode: Self.displayModeTitle(decision.mode),
            status: Self.statusTitle(decision.profile.status),
            setupRequired: decision.setupMessage != nil
        )
    }

    mutating func recordBackendRequest(policy: CompletionRoutingPolicy?) {
        backend = backend.preservingState(
            status: .requested,
            lastError: nil,
            requestedKind: policy?.activeKind
        )
        promptCache = nil
        staleDiscardReason = nil
        output = Output(rawPreview: nil, normalizedPreview: nil)
    }

    mutating func recordBackendSuccess(
        rawText: String?,
        normalizedText: String,
        collectionAllowed: Bool,
        route: CompletionRoute?
    ) {
        backend = backend.preservingState(
            status: .success,
            lastError: nil,
            requestedKind: route?.requestedKind,
            deliveredKind: route?.deliveredKind
        )
        if let route,
           let fallbackErrorDescription = route.fallbackErrorDescription {
            backend = backend.recordingError(fallbackErrorDescription, for: route.requestedKind)
        }
        staleDiscardReason = nil
        output = Output(
            rawPreview: collectionAllowed ? Self.preview(rawText) : nil,
            normalizedPreview: collectionAllowed ? Self.preview(normalizedText) : nil
        )
    }

    mutating func recordBackendFailure(_ error: Error, kind: CompletionEngineKind?) {
        let message = Self.message(for: error)
        backend = backend
            .preservingState(status: .failed, lastError: message, requestedKind: kind)
            .recordingError(message, for: kind)
        promptCache = nil
        output = Output(rawPreview: nil, normalizedPreview: nil)
        recordLastDecision(
            state: .blocked,
            reason: .backendError,
            action: "Backend request failed."
        )
    }

    mutating func recordBackendPaused(_ summary: BackendStatusSummary) {
        recordLastDecision(
            state: .paused,
            reason: .backendCircuitBreaker,
            action: summary.menuTitle
        )
    }

    mutating func recordStaleDiscard(reason: String) {
        backend = backend.preservingState(status: .discarded, lastError: nil)
        promptCache = nil
        staleDiscardReason = reason
        output = Output(rawPreview: nil, normalizedPreview: nil)
        recordLastDecision(
            state: .skipped,
            reason: .poorGeometry,
            action: "Focused text changed before completion could be shown."
        )
    }

    mutating func recordPromptCache(_ stats: LlamaPromptCacheStats?) {
        guard let stats else {
            promptCache = nil
            return
        }
        promptCache = PromptCache(
            hits: stats.hits,
            misses: stats.misses,
            resets: stats.resets,
            retainedPromptTokens: stats.retainedPromptTokens,
            contextTokens: stats.contextTokens
        )
    }

    private static func preview(_ text: String?) -> String? {
        guard let text, !text.isEmpty else {
            return nil
        }
        let collapsed = text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
        if collapsed.count <= 96 {
            return collapsed
        }
        return String(collapsed.prefix(93)) + "..."
    }

    private static func displayModeTitle(_ mode: SuggestionDisplayMode) -> String {
        switch mode {
        case .inline:
            return "inline"
        case .mirrorWindow:
            return "mirror window"
        case .disabled:
            return "disabled"
        }
    }

    private static func statusTitle(_ status: CompatibilityStatus) -> String {
        switch status {
        case .works:
            return "works"
        case .setupNeeded:
            return "setup needed"
        case .partial:
            return "partial"
        case .mirrorOnly:
            return "mirror only"
        case .unsupported:
            return "unsupported"
        }
    }

    static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }

    mutating func recordLastDecision(
        state: LastDecisionState,
        reason: LastDecisionReason,
        action: String
    ) {
        lastDecision = LastDecision(state: state, reason: reason, action: action)
    }

    private mutating func recordLastDecision(for decision: SuggestionEligibilityDecision) {
        if lastDecision?.state == .paused,
           lastDecision?.reason == .backendCircuitBreaker,
           decision.skipReason == .unchangedContext {
            return
        }

        switch decision.outcome {
        case .eligible:
            recordLastDecision(
                state: .ready,
                reason: .eligible,
                action: "Suggestion request can run."
            )
        case .ineligible(let reason):
            let mapped = Self.lastDecision(for: reason)
            recordLastDecision(
                state: mapped.state,
                reason: mapped.reason,
                action: mapped.action
            )
        }
    }

    private static func lastDecision(
        for reason: SuggestionEligibilitySkipReason
    ) -> (state: LastDecisionState, reason: LastDecisionReason, action: String) {
        switch reason {
        case .compatibility:
            return (
                .disabled,
                .appProfile,
                "Current app or domain is disabled by compatibility settings."
            )
        case .emptyContext:
            return (
                .skipped,
                .noMeaningfulPrefix,
                "Type a meaningful prefix before requesting a suggestion."
            )
        case .inputSourceNonASCII, .imeCompositionActive:
            return (
                .blocked,
                .ime,
                "Finish composition, switch input source, or use manual trigger."
            )
        case .selectionActive:
            return (
                .waiting,
                .selectionActive,
                "Use the manual trigger to replace selected text."
            )
        case .sentenceComplete:
            return (
                .skipped,
                .sentenceComplete,
                "Sentence appears complete."
            )
        case .unchangedContext:
            return (
                .skipped,
                .unchangedContext,
                "Focused text has not changed."
            )
        case .awaitingSpaceTrigger:
            return (
                .waiting,
                .waitingForSpace,
                "Waiting for a word boundary."
            )
        case .manualOnlyWaitingForTrigger:
            return (
                .waiting,
                .manualTriggerOnly,
                "Use the manual trigger in this app or domain."
            )
        }
    }
}
