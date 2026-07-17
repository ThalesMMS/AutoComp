import AutoCompCore
import Foundation

enum InlineCommandKind: String, CaseIterable, Sendable {
    case emoji
    case macro
}

struct InlineCommandCaptureState: Equatable, Sendable {
    let kind: InlineCommandKind
    let queryUTF16Length: Int
    let stableFieldIdentity: StableFieldIdentity?
}

struct InlineCommandReplacementPlan: Equatable, Sendable {
    let expectedLiteral: String
    let replacementText: String
    let stableFieldIdentity: StableFieldIdentity?

    var replacementUTF16Length: Int { expectedLiteral.utf16.count }
    var replacementCharacterCount: Int { expectedLiteral.count }

    func validates(_ context: TextContext) -> Bool {
        if let stableFieldIdentity {
            guard context.stableFieldIdentity == stableFieldIdentity else {
                return false
            }
        }
        return context.textBeforeCursor.hasSuffix(expectedLiteral)
    }
}

struct InlineCommandKeyboardCapabilities: Equatable, Sendable {
    var canAccept: Bool
    var canNavigate: Bool

    static let inactive = InlineCommandKeyboardCapabilities(canAccept: false, canNavigate: false)
    static let singleResult = InlineCommandKeyboardCapabilities(canAccept: true, canNavigate: false)
    static let selectableResults = InlineCommandKeyboardCapabilities(canAccept: true, canNavigate: true)
}

enum InlineCommandReason: String, CaseIterable, Sendable {
    case opened
    case updated
    case committed
    case cancelled
    case staleTarget = "stale-target"
    case unsupported
    case secureField = "secure-field"
    case compositionActive = "composition-active"
    case pipelineSuspended = "pipeline-suspended"
}

struct InlineCommandDiagnosticSnapshot: Equatable, Sendable {
    let lastKind: InlineCommandKind?
    let lastReason: InlineCommandReason?
    let countsByReason: [InlineCommandReason: Int]
}

@MainActor
final class InlineCommandDiagnostics {
    private(set) var snapshot = InlineCommandDiagnosticSnapshot(
        lastKind: nil,
        lastReason: nil,
        countsByReason: [:]
    )
    private let traceRecorder: any CompletionTraceRecording
    private var traceContexts: [InlineCommandKind: CompletionTraceContext] = [:]

    init(traceRecorder: any CompletionTraceRecording = NoopCompletionTraceRecorder()) {
        self.traceRecorder = traceRecorder
    }

    func record(
        kind: InlineCommandKind,
        reason: InlineCommandReason,
        queryUTF16Length: Int? = nil
    ) {
        var counts = snapshot.countsByReason
        counts[reason, default: 0] += 1
        snapshot = InlineCommandDiagnosticSnapshot(
            lastKind: kind,
            lastReason: reason,
            countsByReason: counts
        )
        GeometryDebug.log("inline-command kind=\(kind.rawValue) reason=\(reason.rawValue)")

        if reason == .opened || traceContexts[kind] == nil {
            traceContexts[kind] = CompletionTraceContext()
        }
        guard let context = traceContexts[kind] else { return }
        traceRecorder.record(CompletionTraceEvent(
            context: context,
            event: reason.traceEvent,
            reason: reason.traceReason,
            outcome: reason.traceOutcome,
            inlineCommandKind: kind.traceKind,
            inlineCommandQueryUTF16Length: queryUTF16Length
        ))
        if reason.isTerminal {
            traceContexts[kind] = nil
        }
    }
}

@MainActor
protocol InlineCommandControlling: AnyObject {
    var kind: InlineCommandKind { get }
    var isActive: Bool { get }
    var captureState: InlineCommandCaptureState? { get }
    var keyboardCapabilities: InlineCommandKeyboardCapabilities { get }
    var onActiveChanged: ((Bool) -> Void)? { get set }

    func handleInputEvent(_ event: CapturedInputEvent) async -> Bool
    func handleKeyboardCommand(_ command: InlineCommandKeyboardCommand) async
    func cancel(reason: InlineCommandReason)
}

private extension InlineCommandKind {
    var traceKind: CompletionTraceInlineCommandKind {
        switch self {
        case .emoji: .emoji
        case .macro: .macro
        }
    }
}

private extension InlineCommandReason {
    var traceEvent: CompletionTraceEventName {
        switch self {
        case .opened: .inlineCommandOpened
        case .updated, .unsupported: .inlineCommandUpdated
        case .committed: .inlineCommandCommitted
        case .cancelled, .staleTarget, .secureField, .compositionActive, .pipelineSuspended:
            .inlineCommandCancelled
        }
    }

    var traceReason: CompletionTraceReasonCode? {
        switch self {
        case .opened, .updated: nil
        case .committed: .completed
        case .cancelled: .dismissed
        case .staleTarget: .staleTarget
        case .unsupported: .unsupported
        case .secureField: .secureField
        case .compositionActive: .compositionActive
        case .pipelineSuspended: .pipelineSuspended
        }
    }

    var traceOutcome: CompletionTraceOutcome {
        switch self {
        case .opened: .started
        case .updated: .ready
        case .committed: .inserted
        case .unsupported: .rejected
        case .cancelled, .staleTarget, .secureField, .compositionActive, .pipelineSuspended:
            .cancelled
        }
    }

    var isTerminal: Bool {
        switch self {
        case .committed, .cancelled, .staleTarget, .secureField, .compositionActive, .pipelineSuspended:
            true
        case .opened, .updated, .unsupported:
            false
        }
    }
}
