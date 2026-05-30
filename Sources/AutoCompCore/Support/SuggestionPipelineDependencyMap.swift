import Foundation

/// Documents (in code) how `SuggestionEngine` orchestration is currently wired.
///
/// This file is intentionally documentation-oriented: it centralizes the list of
/// collaborators injected into `SuggestionEngine` and describes—at a high level—
/// which orchestration responsibilities depend on which collaborators.
///
/// The goal is to support incremental extraction into pipeline steps without
/// passing the entire engine into each step.
public enum SuggestionPipelineDependencyMap {

    /// A single collaborator injected into `SuggestionEngine`.
    public struct Collaborator: Sendable, Equatable {
        public let name: String
        public let typeName: String
        public let usedFor: [String]

        public init(name: String, typeName: String, usedFor: [String]) {
            self.name = name
            self.typeName = typeName
            self.usedFor = usedFor
        }
    }

    /// High-level data passed through the current orchestration.
    ///
    /// This is not a runtime model yet—just a canonical list so we can converge on
    /// a future `RequestContext` design.
    public struct DataFlowItem: Sendable, Equatable {
        public let name: String
        public let producedBy: String
        public let consumedBy: [String]

        public init(name: String, producedBy: String, consumedBy: [String]) {
            self.name = name
            self.producedBy = producedBy
            self.consumedBy = consumedBy
        }
    }

    /// Current `SuggestionEngine` initializer collaborators.
    public static let collaborators: [Collaborator] = [
        .init(
            name: "focusProvider",
            typeName: "TextContextProvider",
            usedFor: [
                "Capture current editor focus + text snapshot (AX)",
                "Populate `TextContext` used by eligibility + provider prompt"
            ]
        ),
        .init(
            name: "generationProvider",
            typeName: "CompletionProvider",
            usedFor: [
                "Async completion generation",
                "Provider cancellation / lifecycle generation changes"
            ]
        ),
        .init(
            name: "backendHealthMonitor",
            typeName: "BackendHealthMonitor",
            usedFor: [
                "Suppression gates when backend is paused/unhealthy",
                "Publish backend status summary"
            ]
        ),
        .init(
            name: "visualContextProvider",
            typeName: "VisualContextProvider?",
            usedFor: [
                "Optional visual context capture (screenshot/geometry)",
                "Eligibility and staleness checks around visual capture"
            ]
        ),
        .init(
            name: "clipboardContextProvider",
            typeName: "ClipboardContextProvider?",
            usedFor: [
                "Optional clipboard context capture",
                "Augment provider request context"
            ]
        ),
        .init(
            name: "presenter",
            typeName: "SuggestionPresenter",
            usedFor: [
                "Show/hide inline preview",
                "Render current suggestion"
            ]
        ),
        .init(
            name: "inputController",
            typeName: "SuggestionInputStateTracking",
            usedFor: [
                "Track user input events and mutations",
                "Dismiss-until-mutation behavior",
                "Debounce scheduling"
            ]
        ),
        .init(
            name: "compatibilityCatalog",
            typeName: "CompatibilityCatalog",
            usedFor: [
                "Host app compatibility profile",
                "Per-app suppression / risky-host policies"
            ]
        ),
        .init(
            name: "compatibilitySettings",
            typeName: "CompatibilitySettingsStore",
            usedFor: [
                "User-configured per-app compatibility overrides",
                "Allow/deny list style gates"
            ]
        ),
        .init(
            name: "privacyStore",
            typeName: "PrivacySettingsStore",
            usedFor: [
                "Private mode / sensitive field gates",
                "User privacy settings for capture / sending"
            ]
        ),
        .init(
            name: "productivityMetrics",
            typeName: "ProductivityMetricsRecording?",
            usedFor: [
                "Record acceptance / generation outcomes",
                "Attach request ids and timings"
            ]
        ),
        .init(
            name: "eligibilityEvaluator",
            typeName: "SuggestionEligibilityEvaluator",
            usedFor: [
                "Eligibility of current text for suggestion",
                "Heuristics: empty text, whitespace drift, etc."
            ]
        ),
        .init(
            name: "inputMethodStateProvider",
            typeName: "() -> InputMethodState",
            usedFor: [
                "IME state gating (e.g., non-ascii compatible)",
                "Eligibility adjustments"
            ]
        ),
        .init(
            name: "keystrokeBufferFallback",
            typeName: "KeystrokeBufferFallback?",
            usedFor: [
                "Fallback to local keystroke buffer when AX is unreliable"
            ]
        ),
        .init(
            name: "publicationController",
            typeName: "SuggestionPublicationController",
            usedFor: [
                "Publish suggestion to presenter",
                "Coordinate inline preview triggers"
            ]
        ),
        .init(
            name: "acceptanceSessionController",
            typeName: "AcceptanceSessionController",
            usedFor: [
                "Track active suggestion sessions",
                "Support acceptance reconciliation"
            ]
        ),
        .init(
            name: "acceptanceController",
            typeName: "SuggestionAcceptanceController",
            usedFor: [
                "Handle accept-next-word / accept-all behaviors",
                "Apply accepted text back into the host"
            ]
        ),
        .init(
            name: "shortcutLeakRepairInserter",
            typeName: "ShortcutLeakRepairing?",
            usedFor: [
                "Insert repair text for shortcut leaks",
                "Provider prompt hygiene"
            ]
        ),
        .init(
            name: "emojiService",
            typeName: "EmojiSuggestionService",
            usedFor: [
                "Emoji suggestion generation path"
            ]
        ),
        .init(
            name: "lifecycleController",
            typeName: "SuggestionLifecycleController",
            usedFor: [
                "Timer/poll lifecycle for refresh()",
                "Start/stop orchestration"
            ]
        ),
        .init(
            name: "predictionController",
            typeName: "SuggestionPredictionController",
            usedFor: [
                "Debounce and in-flight request cancellation",
                "Stale-work detection via work ids"
            ]
        ),
        .init(
            name: "diagnosticsController",
            typeName: "SuggestionDiagnosticsController",
            usedFor: [
                "Track request timings",
                "Record discard reasons and provider metadata"
            ]
        ),
        .init(
            name: "contextGenerationTracker",
            typeName: "ContextGenerationTracker",
            usedFor: [
                "Detect backend/provider switches",
                "Avoid publishing stale results after switching"
            ]
        ),
        .init(
            name: "suggestionDebugLogger",
            typeName: "SuggestionDebugLogger?",
            usedFor: [
                "Optional verbose debugging logs for suggestions"
            ]
        ),
        .init(
            name: "debugOptionsProvider",
            typeName: "() -> AutoCompDebugOptions",
            usedFor: [
                "Runtime debug flags affecting orchestration"
            ]
        )
    ]

    /// Canonical list of major data passed between orchestration steps.
    public static let dataFlow: [DataFlowItem] = [
        .init(
            name: "Work identifier (prediction work id / request id)",
            producedBy: "SuggestionPredictionController / SuggestionEngine",
            consumedBy: [
                "Stale-work checks before/after provider",
                "Diagnostics correlation",
                "Publication gating"
            ]
        ),
        .init(
            name: "TextContext (editor snapshot)",
            producedBy: "TextContextProvider (AX capture) + SuggestionEngine",
            consumedBy: [
                "Eligibility evaluator",
                "Prompt builder / provider request factory",
                "Publication (to keep context+sugg aligned)"
            ]
        ),
        .init(
            name: "Invocation metadata (automatic vs manual)",
            producedBy: "SuggestionEngine",
            consumedBy: [
                "Debounce rules",
                "Diagnostics",
                "Suppression gates"
            ]
        ),
        .init(
            name: "Compatibility profile + settings",
            producedBy: "CompatibilityCatalog + CompatibilitySettingsStore",
            consumedBy: [
                "Suppression gates",
                "Privacy gates",
                "Risky-host acceptance gating"
            ]
        ),
        .init(
            name: "Privacy settings / private mode",
            producedBy: "PrivacySettingsStore",
            consumedBy: [
                "Privacy gate for request",
                "Decision to include visual/clipboard context"
            ]
        ),
        .init(
            name: "Optional VisualContextSnapshot",
            producedBy: "VisualContextProvider",
            consumedBy: [
                "Provider request augmentation",
                "Post-capture staleness validation"
            ]
        ),
        .init(
            name: "Optional ClipboardContextSnapshot",
            producedBy: "ClipboardContextProvider",
            consumedBy: [
                "Provider request augmentation"
            ]
        ),
        .init(
            name: "Provider request (prompt, stop sequences, model selection)",
            producedBy: "CompletionRequestFactory / PromptBuilder",
            consumedBy: [
                "CompletionProvider"
            ]
        ),
        .init(
            name: "Provider response (completion text / candidates)",
            producedBy: "CompletionProvider",
            consumedBy: [
                "Revalidation against current context",
                "Publication controller",
                "Diagnostics + metrics"
            ]
        ),
        .init(
            name: "SuggestionDiagnostics",
            producedBy: "SuggestionDiagnosticsController",
            consumedBy: [
                "UI status/debug surfaces",
                "Logging / metrics"
            ]
        )
    ]
}
