import Foundation

/// Opaque correlation identifier for one logical completion lifecycle.
public struct CompletionTraceID: Codable, Equatable, Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

/// Correlation metadata that survives provider attempts and presentation.
public struct CompletionTraceContext: Equatable, Sendable {
    public let traceID: CompletionTraceID
    public let parentTraceID: CompletionTraceID?
    public let originTraceID: CompletionTraceID?
    public let presentationAttempt: Int

    public init(
        traceID: CompletionTraceID = CompletionTraceID(),
        parentTraceID: CompletionTraceID? = nil,
        originTraceID: CompletionTraceID? = nil,
        presentationAttempt: Int = 0
    ) {
        self.traceID = traceID
        self.parentTraceID = parentTraceID
        self.originTraceID = originTraceID
        self.presentationAttempt = max(0, presentationAttempt)
    }
}

/// Versioned names for the redacted local completion timeline.
public enum CompletionTraceEventName: String, Codable, CaseIterable, Sendable {
    case inputObserved = "input-observed"
    case hostPublishStarted = "host-publish-started"
    case hostPublishReady = "host-publish-ready"
    case hostPublishTimeout = "host-publish-timeout"
    case hostPublishCancelled = "host-publish-cancelled"
    case schedulingDecided = "scheduling-decided"
    case debounceStarted = "debounce-started"
    case debounceElapsed = "debounce-elapsed"
    case debounceCancelled = "debounce-cancelled"
    case contextCaptured = "context-captured"
    case eligibilityDecided = "eligibility-decided"
    case privacyGateDecided = "privacy-gate-decided"
    case requestBuilt = "request-built"
    case providerStarted = "provider-started"
    case providerCompleted = "provider-completed"
    case providerFailed = "provider-failed"
    case providerCancelled = "provider-cancelled"
    case streamPartialReceived = "stream-partial-received"
    case streamPartialRendered = "stream-partial-rendered"
    case streamPartialCoalesced = "stream-partial-coalesced"
    case streamPartialIgnored = "stream-partial-ignored"
    case streamFinalReceived = "stream-final-received"
    case streamEarlyAccepted = "stream-early-accepted"
    case streamFinalSuppressed = "stream-final-suppressed"
    case fallbackStarted = "fallback-started"
    case normalized
    case reusePromoted = "reuse-promoted"
    case reuseRollbackRestored = "reuse-rollback-restored"
    case reuseMiss = "reuse-miss"
    case speculationStarted = "speculation-started"
    case speculationValidated = "speculation-validated"
    case speculationDiverged = "speculation-diverged"
    case liveContextRevalidated = "live-context-revalidated"
    case publicationRejected = "publication-rejected"
    case published
    case overlayPresented = "overlay-presented"
    case overlayHidden = "overlay-hidden"
    case acceptanceAttempted = "acceptance-attempted"
    case acceptanceAllowed = "acceptance-allowed"
    case acceptanceBlocked = "acceptance-blocked"
    case acceptanceInserted = "acceptance-inserted"
    case sessionAdvanced = "session-advanced"
    case sessionExhausted = "session-exhausted"
    case sessionDiverged = "session-diverged"
    case inlineCommandOpened = "inline-command-opened"
    case inlineCommandUpdated = "inline-command-updated"
    case inlineCommandCommitted = "inline-command-committed"
    case inlineCommandCancelled = "inline-command-cancelled"
    case traceFinished = "trace-finished"
}

/// Closed reason codes prevent user content from being smuggled into trace data.
public enum CompletionTraceReasonCode: String, Codable, Sendable {
    case automatic
    case manual
    case pipelineSuspended = "pipeline-suspended"
    case backendPaused = "backend-paused"
    case taskCancelled = "task-cancelled"
    case staleWork = "stale-work"
    case staleContext = "stale-context"
    case providerFailure = "provider-failure"
    case fallback
    case publicationRejected = "publication-rejected"
    case reuseMiss = "reuse-miss"
    case acceptanceBlocked = "acceptance-blocked"
    case exhausted
    case diverged
    case dismissed
    case focusChanged = "focus-changed"
    case staleTarget = "stale-target"
    case unsupported
    case secureField = "secure-field"
    case compositionActive = "composition-active"
    case superseded
    case timeout
    case completed
    case unknown
}

public enum CompletionTraceInlineCommandKind: String, Codable, Sendable {
    case emoji
    case macro
}

public enum CompletionTraceOutcome: String, Codable, Sendable {
    case started
    case ready
    case allowed
    case blocked
    case cancelled
    case discarded
    case failed
    case rejected
    case published
    case inserted
    case advanced
    case exhausted
    case finished
}

/// Privacy-safe JSONL record. It intentionally has no free-form text fields.
public struct CompletionTraceEvent: Codable, Equatable, Sendable {
    public static let currentSchemaVersion = 6

    public let schemaVersion: Int
    public let traceID: CompletionTraceID
    public let parentTraceID: CompletionTraceID?
    public let originTraceID: CompletionTraceID?
    public let presentationAttempt: Int
    public let event: CompletionTraceEventName
    public let reason: CompletionTraceReasonCode?
    public let outcome: CompletionTraceOutcome?
    public let timestamp: Date
    public let workID: Int?
    public let providerAttempt: Int?
    public let durationMs: Int?
    public let requestedBackend: CompletionEngineKind?
    public let deliveredBackend: CompletionEngineKind?
    public let prefixUTF16Length: Int?
    public let suffixUTF16Length: Int?
    public let candidateCount: Int?
    public let candidateRank: Int?
    public let hostPublishOutcome: SuggestionSchedulingHostPublishOutcome?
    public let hostPublishMs: Int?
    public let hostPublishPollCount: Int?
    public let targetDebounceMs: Int?
    public let remainingDebounceMs: Int?
    public let schedulingReason: SuggestionSchedulingReason?
    public let recentBackendLatencyMs: Int?
    public let providerCallStarted: Bool?
    public let reuseSnapshotAgeBucket: Int?
    public let remainingCharacterBucket: Int?
    public let inlineCommandKind: CompletionTraceInlineCommandKind?
    public let inlineCommandQueryUTF16Length: Int?
    public let providerSequence: Int?
    public let partialCount: Int?
    public let timeToFirstSafePartialMs: Int?
    public let timeToFinalMs: Int?
    public let earlyAcceptance: Bool?

    public init(
        context: CompletionTraceContext,
        event: CompletionTraceEventName,
        reason: CompletionTraceReasonCode? = nil,
        outcome: CompletionTraceOutcome? = nil,
        timestamp: Date = Date(),
        workID: Int? = nil,
        providerAttempt: Int? = nil,
        durationMs: Int? = nil,
        requestedBackend: CompletionEngineKind? = nil,
        deliveredBackend: CompletionEngineKind? = nil,
        prefixUTF16Length: Int? = nil,
        suffixUTF16Length: Int? = nil,
        candidateCount: Int? = nil,
        candidateRank: Int? = nil,
        hostPublishOutcome: SuggestionSchedulingHostPublishOutcome? = nil,
        hostPublishMs: Int? = nil,
        hostPublishPollCount: Int? = nil,
        targetDebounceMs: Int? = nil,
        remainingDebounceMs: Int? = nil,
        schedulingReason: SuggestionSchedulingReason? = nil,
        recentBackendLatencyMs: Int? = nil,
        providerCallStarted: Bool? = nil,
        reuseSnapshotAgeBucket: Int? = nil,
        remainingCharacterBucket: Int? = nil,
        inlineCommandKind: CompletionTraceInlineCommandKind? = nil,
        inlineCommandQueryUTF16Length: Int? = nil,
        providerSequence: Int? = nil,
        partialCount: Int? = nil,
        timeToFirstSafePartialMs: Int? = nil,
        timeToFinalMs: Int? = nil,
        earlyAcceptance: Bool? = nil
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.traceID = context.traceID
        self.parentTraceID = context.parentTraceID
        self.originTraceID = context.originTraceID
        self.presentationAttempt = context.presentationAttempt
        self.event = event
        self.reason = reason
        self.outcome = outcome
        self.timestamp = timestamp
        self.workID = workID
        self.providerAttempt = providerAttempt
        self.durationMs = durationMs.map { max(0, $0) }
        self.requestedBackend = requestedBackend
        self.deliveredBackend = deliveredBackend
        self.prefixUTF16Length = prefixUTF16Length.map { max(0, $0) }
        self.suffixUTF16Length = suffixUTF16Length.map { max(0, $0) }
        self.candidateCount = candidateCount.map { max(0, $0) }
        self.candidateRank = candidateRank.map { max(0, $0) }
        self.hostPublishOutcome = hostPublishOutcome
        self.hostPublishMs = hostPublishMs.map { max(0, $0) }
        self.hostPublishPollCount = hostPublishPollCount.map { max(0, $0) }
        self.targetDebounceMs = targetDebounceMs.map { max(0, $0) }
        self.remainingDebounceMs = remainingDebounceMs.map { max(0, $0) }
        self.schedulingReason = schedulingReason
        self.recentBackendLatencyMs = recentBackendLatencyMs.map { max(0, $0) }
        self.providerCallStarted = providerCallStarted
        self.reuseSnapshotAgeBucket = reuseSnapshotAgeBucket.map { max(0, $0) }
        self.remainingCharacterBucket = remainingCharacterBucket.map { max(0, $0) }
        self.inlineCommandKind = inlineCommandKind
        self.inlineCommandQueryUTF16Length = inlineCommandQueryUTF16Length.map { max(0, $0) }
        self.providerSequence = providerSequence.map { max(0, $0) }
        self.partialCount = partialCount.map { max(0, $0) }
        self.timeToFirstSafePartialMs = timeToFirstSafePartialMs.map { max(0, $0) }
        self.timeToFinalMs = timeToFinalMs.map { max(0, $0) }
        self.earlyAcceptance = earlyAcceptance
    }
}

public protocol CompletionTraceRecording: Sendable {
    func record(_ event: CompletionTraceEvent)
}

public struct NoopCompletionTraceRecorder: CompletionTraceRecording {
    public init() {}
    public func record(_ event: CompletionTraceEvent) {}
}
