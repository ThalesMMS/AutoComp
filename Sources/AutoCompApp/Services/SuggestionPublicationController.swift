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
        collectionAllowed: Bool,
        updateExisting: Bool = false
    ) -> SuggestionPublicationResult {
        let normalizationStartedAt = ContinuousClock.now
        let policyDecision = SuggestionPublicationPolicy.evaluate(suggestion, for: context)
        let normalizationMs = normalizationStartedAt.duration(to: .now).milliseconds
        guard case .publish(let normalizedSuggestion) = policyDecision else {
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
        if updateExisting {
            presenter.update(normalizedSuggestion, for: context, mode: displayMode)
        } else {
            presenter.show(normalizedSuggestion, for: context, mode: displayMode)
        }
        let overlayMs = overlayStartedAt.duration(to: .now).milliseconds
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
