import AutoCompCore
import Foundation

private enum AcceptanceTextDelta {
    static func trimmingSuffixOverlap(token: String, suffix: String?) -> String {
        guard let suffix, !suffix.isEmpty, !token.isEmpty else {
            return token
        }
        guard token.hasSuffix(suffix) else {
            return token
        }
        return String(token.dropLast(suffix.count))
    }
}

struct SuggestionAcceptanceResult: Equatable {
    let currentSuggestion: Suggestion?
    let presentationContext: TextContext?
    let acceptedText: String
    let completedAcceptAllStateArmed: Bool

    var shouldHidePresenter: Bool {
        currentSuggestion == nil
    }
}

@MainActor
final class SuggestionAcceptanceController {
    private let sessionController: AcceptanceSessionController

    init(sessionController: AcceptanceSessionController) {
        self.sessionController = sessionController
    }

    func acceptNextWord(
        currentSuggestion: Suggestion?,
        currentContext: TextContext?,
        using inserter: TextInserter
    ) async throws -> SuggestionAcceptanceResult? {
        guard var suggestion = currentSuggestion else {
            return nil
        }

        let previousContext = currentContext
        let previousSuggestion = suggestion

        // Compute the insertion delta against the *current* host suffix so we don't duplicate
        // text already present after the cursor in fill-in-middle scenarios.
        let expectedSuffix = previousContext?.textAfterCursor
        guard let acceptedToken = suggestion.acceptNextWord() else {
            return nil
        }
        let acceptedText = AcceptanceTextDelta.trimmingSuffixOverlap(
            token: acceptedToken,
            suffix: expectedSuffix
        )

        if !acceptedText.isEmpty {
            try inserter.insert(acceptedText)
        }

        sessionController.recordAcceptance(
            previousContext: previousContext,
            previousSuggestion: previousSuggestion,
            updatedSuggestion: suggestion,
            acceptedText: acceptedText
        )
        let suggestionWasExhausted = suggestion.isExhausted
        let acceptAllStateArmed = suggestionWasExhausted
            ? sessionController.armCompletedAcceptAll()
            : false
        let nextSuggestion = suggestionWasExhausted ? nil : suggestion
        let presentationContext = currentContext.flatMap {
            predictedPresentationContext(afterAccepting: acceptedText, from: $0)
        }

        return SuggestionAcceptanceResult(
            currentSuggestion: nextSuggestion,
            presentationContext: presentationContext,
            acceptedText: acceptedText,
            completedAcceptAllStateArmed: acceptAllStateArmed
        )
    }

    func acceptAll(
        currentSuggestion: Suggestion?,
        currentContext: TextContext?,
        using inserter: TextInserter
    ) async throws -> SuggestionAcceptanceResult? {
        guard var suggestion = currentSuggestion else {
            return nil
        }

        let previousContext = currentContext
        let previousSuggestion = suggestion

        let expectedSuffix = previousContext?.textAfterCursor
        guard let acceptedToken = suggestion.acceptAll() else {
            return nil
        }
        let acceptedText = AcceptanceTextDelta.trimmingSuffixOverlap(
            token: acceptedToken,
            suffix: expectedSuffix
        )

        if !acceptedText.isEmpty {
            try inserter.insert(acceptedText)
        }

        sessionController.recordAcceptance(
            previousContext: previousContext,
            previousSuggestion: previousSuggestion,
            updatedSuggestion: suggestion,
            acceptedText: acceptedText
        )
        let acceptAllStateArmed = sessionController.armCompletedAcceptAll()

        return SuggestionAcceptanceResult(
            currentSuggestion: nil,
            presentationContext: nil,
            acceptedText: acceptedText,
            completedAcceptAllStateArmed: acceptAllStateArmed
        )
    }

    private func predictedPresentationContext(
        afterAccepting acceptedText: String,
        from context: TextContext
    ) -> TextContext? {
        guard let predictedContext = CaretPrediction.predictedContext(
            afterAccepting: acceptedText,
            from: context
        ) else {
            return nil
        }

        GeometryDebug.log("caret-prediction acceptedLength=\((acceptedText as NSString).length) oldCaretRect=\(String(describing: context.caretRect)) predictedCaretRect=\(String(describing: predictedContext.caretRect))")
        return predictedContext
    }
}
