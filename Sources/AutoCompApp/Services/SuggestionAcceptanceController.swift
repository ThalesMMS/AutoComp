import AutoCompCore
import Foundation

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
        guard let acceptedText = try await inserter.acceptNextWord(from: &suggestion) else {
            return nil
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
        guard let acceptedText = try await inserter.acceptAll(from: &suggestion) else {
            return nil
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
