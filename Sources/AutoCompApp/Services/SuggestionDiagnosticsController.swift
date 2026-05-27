import AutoCompCore
import Foundation

struct SuggestionDiagnosticsController {
    func contextDescription(_ context: TextContext?) -> String {
        guard let context else {
            return "nil"
        }

        let suffixLength = context.textAfterCursor.map { ($0 as NSString).length } ?? 0
        return "app=\(context.app.displayName) bundle=\(context.app.bundleID) domain=\(context.domain ?? "nil") source=\(sourceDescription(context.captureSources)) len=\((context.textBeforeCursor as NSString).length) suffixLen=\(suffixLength) trailingWhitespace=\(trailingWhitespaceDescription(context.textBeforeCursor)) selectedRange=\(String(describing: context.selectedRange)) focusID=\(context.focusedElementID) geometry=\(context.caretGeometryQuality.rawValue)"
    }

    func suggestionDescription(_ suggestion: Suggestion?) -> String {
        guard let suggestion else {
            return "nil"
        }

        return "visibleLength=\((suggestion.visibleText as NSString).length) remainingLength=\((suggestion.remainingText as NSString).length) exhausted=\(suggestion.isExhausted)"
    }

    func eligibilityDescription(_ decision: SuggestionEligibilityDecision) -> String {
        switch decision.outcome {
        case .eligible:
            return "eligible"
        case .ineligible(let reason):
            return "ineligible:\(reason.rawValue)"
        }
    }

    func logEligibilityDecision(_ decision: SuggestionEligibilityDecision) {
        decision.logs.forEach(logEligibility)
    }

    func logPublicationResult(_ result: SuggestionPublicationResult) {
        result.logs.forEach { log in
            switch log.kind {
            case .published:
                GeometryDebug.log("suggestion-publication result=published app=\(log.appDisplayName) bundle=\(log.bundleID) mode=\(log.displayMode.rawValue) visibleLength=\(log.visibleLength)")
            case .rejected(let reason):
                GeometryDebug.log("suggestion-publication result=rejected reason=\(reason.rawValue) app=\(log.appDisplayName) bundle=\(log.bundleID) mode=\(log.displayMode.rawValue)")
            }
        }
    }

    private func logEligibility(_ log: SuggestionEligibilityLogData) {
        switch log.kind {
        case .eligible:
            GeometryDebug.log("suggestion-eligible app=\(log.appDisplayName) bundle=\(log.bundleID)")
        case .skip(let reason):
            switch reason {
            case .compatibility, .manualOnlyWaitingForTrigger:
                let enabled = log.compatibilityEnabled.map(String.init) ?? "nil"
                GeometryDebug.log("suggestion-skip reason=\(reason.rawValue) app=\(log.appDisplayName) bundle=\(log.bundleID) enabled=\(enabled) mode=\(log.displayMode?.rawValue ?? "nil") status=\(log.compatibilityStatus?.rawValue ?? "nil")")
            default:
                GeometryDebug.log("suggestion-skip reason=\(reason.rawValue) app=\(log.appDisplayName) bundle=\(log.bundleID)")
            }
        case .trigger(let reason):
            GeometryDebug.log("suggestion-trigger reason=\(reason.rawValue) app=\(log.appDisplayName) bundle=\(log.bundleID)")
        }
    }

    private func trailingWhitespaceDescription(_ text: String) -> String {
        guard let lastScalar = text.unicodeScalars.last else {
            return "empty"
        }
        return CharacterSet.whitespacesAndNewlines.contains(lastScalar) ? "true" : "false"
    }

    private func sourceDescription(_ sources: Set<TextCaptureSource>) -> String {
        sources
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")
    }
}
