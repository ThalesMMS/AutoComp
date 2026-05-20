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
        let normalizedSuggestion = self.normalizedSuggestion(suggestion, for: context)
        guard !normalizedSuggestion.visibleText.isEmpty else {
            presenter.hide()
            return SuggestionPublicationResult(
                outcome: .rejected(.emptyAfterNormalization),
                statusMessage: nil,
                lastLatencyMs: nil,
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

        presenter.show(normalizedSuggestion, for: context, mode: displayMode)
        let statusMessage = collectionAllowed
            ? "Suggesting in \(context.app.displayName); collection enabled"
            : "Suggesting in \(context.app.displayName)"

        return SuggestionPublicationResult(
            outcome: .published(normalizedSuggestion),
            statusMessage: statusMessage,
            lastLatencyMs: normalizedSuggestion.latencyMs,
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
