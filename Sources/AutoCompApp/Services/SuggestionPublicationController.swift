import AutoCompCore
import Foundation

enum SuggestionPublicationRejectionReason: String, Codable, CaseIterable, Sendable {
    case emptyAfterNormalization = "empty-after-normalization"
}

enum SuggestionPublicationLogKind: Equatable, Sendable {
    case published
    case rejected(SuggestionPublicationRejectionReason)
}

struct SuggestionPublicationLogData: Equatable, Sendable {
    let kind: SuggestionPublicationLogKind
    let appDisplayName: String
    let bundleID: String
    let displayMode: SuggestionDisplayMode
    let visibleLength: Int
}

enum SuggestionPublicationOutcome: Equatable, Sendable {
    case published(Suggestion)
    case rejected(SuggestionPublicationRejectionReason)
}

struct SuggestionPublicationResult: Equatable, Sendable {
    let outcome: SuggestionPublicationOutcome
    let statusMessage: String?
    let lastLatencyMs: Int?
    let normalizationMs: Int?
    let overlayMs: Int?
    let logs: [SuggestionPublicationLogData]

    var publishedSuggestion: Suggestion? {
        if case .published(let suggestion) = outcome {
            return suggestion
        }
        return nil
    }
}

@MainActor
final class SuggestionPublicationController {
    private let presenter: SuggestionPresenter

    init(presenter: SuggestionPresenter) {
        self.presenter = presenter
    }

    func publish(
        _ suggestion: Suggestion,
        context: TextContext,
        displayMode: SuggestionDisplayMode,
        collectionAllowed: Bool
    ) -> SuggestionPublicationResult {
        let normalizationStartedAt = ContinuousClock.now
        let normalizedSuggestion = self.normalizedSuggestion(suggestion, for: context)
        let normalizationMs = normalizationStartedAt.duration(to: .now).appMilliseconds
        guard !normalizedSuggestion.visibleText.isEmpty else {
            presenter.hide()
            return SuggestionPublicationResult(
                outcome: .rejected(.emptyAfterNormalization),
                statusMessage: nil,
                lastLatencyMs: nil,
                normalizationMs: normalizationMs,
                overlayMs: nil,
                logs: [
                    log(
                        kind: .rejected(.emptyAfterNormalization),
                        context: context,
                        displayMode: displayMode,
                        visibleLength: 0
                    )
                ]
            )
        }

        let overlayStartedAt = ContinuousClock.now
        presenter.show(normalizedSuggestion, for: context, mode: displayMode)
        let overlayMs = overlayStartedAt.duration(to: .now).appMilliseconds
        var statusParts = ["Suggesting in \(context.app.displayName)"]
        if normalizedSuggestion.hasMultipleAlternatives {
            statusParts.append("alternative \(normalizedSuggestion.selectedAlternativeIndex + 1) of \(normalizedSuggestion.alternatives.count)")
        }
        if collectionAllowed {
            statusParts.append("collection enabled")
        }
        let statusMessage = statusParts.joined(separator: "; ")

        return SuggestionPublicationResult(
            outcome: .published(normalizedSuggestion),
            statusMessage: statusMessage,
            lastLatencyMs: normalizedSuggestion.latencyMs,
            normalizationMs: normalizationMs,
            overlayMs: overlayMs,
            logs: [
                log(
                    kind: .published,
                    context: context,
                    displayMode: displayMode,
                    visibleLength: (normalizedSuggestion.visibleText as NSString).length
                )
            ]
        )
    }

    private func normalizedSuggestion(_ suggestion: Suggestion, for context: TextContext) -> Suggestion {
        guard textEndsWithSuggestionTriggerWhitespace(context.textBeforeCursor) else {
            return suggestion
        }

        var normalized = suggestion
        normalized.visibleText = droppingLeadingWhitespace(from: normalized.visibleText)
        normalized.remainingText = droppingLeadingWhitespace(from: normalized.remainingText)
        return normalized
    }

    private func droppingLeadingWhitespace(from text: String) -> String {
        let firstNonWhitespace = text.unicodeScalars.firstIndex {
            !CharacterSet.whitespacesAndNewlines.contains($0)
        }
        guard let firstNonWhitespace else {
            return ""
        }
        return String(text.unicodeScalars[firstNonWhitespace...])
    }

    private func textEndsWithSuggestionTriggerWhitespace(_ text: String) -> Bool {
        guard let lastScalar = text.unicodeScalars.last else {
            return false
        }
        return CharacterSet.whitespacesAndNewlines.contains(lastScalar)
    }

    private func log(
        kind: SuggestionPublicationLogKind,
        context: TextContext,
        displayMode: SuggestionDisplayMode,
        visibleLength: Int
    ) -> SuggestionPublicationLogData {
        SuggestionPublicationLogData(
            kind: kind,
            appDisplayName: context.app.displayName,
            bundleID: context.app.bundleID,
            displayMode: displayMode,
            visibleLength: visibleLength
        )
    }
}
