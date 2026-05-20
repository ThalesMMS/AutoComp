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
        let geometryQuality: String
        let hasCaretRect: Bool
        let hasFocusedElementRect: Bool
    }

    struct Eligibility: Equatable {
        let outcome: String
        let skipReason: String?
        let statusMessage: String?
    }

    struct Backend: Equatable {
        let status: SuggestionBackendDiagnosticStatus
        let lastError: String?
    }

    struct Output: Equatable {
        let rawPreview: String?
        let normalizedPreview: String?
    }

    var focus: Focus?
    var eligibility: Eligibility?
    var backend = Backend(status: .idle, lastError: nil)
    var staleDiscardReason: String?
    var output = Output(rawPreview: nil, normalizedPreview: nil)

    var menuRows: [SuggestionDiagnosticRow] {
        var rows: [SuggestionDiagnosticRow] = []
        if let focus {
            rows.append(SuggestionDiagnosticRow(id: "focus", title: "Focus", value: focus.appDisplayName))
            rows.append(SuggestionDiagnosticRow(id: "geometry", title: "Geometry", value: focus.geometryQuality))
            if let domain = focus.domain {
                rows.append(SuggestionDiagnosticRow(id: "domain", title: "Domain", value: domain))
            }
        }
        if let eligibility {
            let value = eligibility.skipReason ?? eligibility.outcome
            rows.append(SuggestionDiagnosticRow(id: "eligibility", title: "Eligibility", value: value))
        }
        rows.append(SuggestionDiagnosticRow(id: "backend", title: "Backend", value: backend.status.rawValue))
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
        focus = Focus(
            appDisplayName: context.app.displayName,
            bundleID: context.app.bundleID,
            domain: context.domain,
            focusedElementID: context.focusedElementID,
            geometryQuality: context.caretGeometryQuality.rawValue,
            hasCaretRect: context.caretRect != nil,
            hasFocusedElementRect: context.focusedElementRect != nil
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
    }

    mutating func recordBackendRequest() {
        backend = Backend(status: .requested, lastError: nil)
        staleDiscardReason = nil
        output = Output(rawPreview: nil, normalizedPreview: nil)
    }

    mutating func recordBackendSuccess(
        rawText: String?,
        normalizedText: String,
        collectionAllowed: Bool
    ) {
        backend = Backend(status: .success, lastError: nil)
        staleDiscardReason = nil
        output = Output(
            rawPreview: collectionAllowed ? Self.preview(rawText) : nil,
            normalizedPreview: collectionAllowed ? Self.preview(normalizedText) : nil
        )
    }

    mutating func recordBackendFailure(_ error: Error) {
        backend = Backend(status: .failed, lastError: Self.message(for: error))
        output = Output(rawPreview: nil, normalizedPreview: nil)
    }

    mutating func recordStaleDiscard(reason: String) {
        backend = Backend(status: .discarded, lastError: nil)
        staleDiscardReason = reason
        output = Output(rawPreview: nil, normalizedPreview: nil)
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

    static func message(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
