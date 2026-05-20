import Foundation

@MainActor
protocol SuggestionInputStateTracking: AnyObject {
    var lastSuggestionTriggerKeyAt: Date { get }
    func record(_ event: CapturedInputEvent)
    func clearSuggestionTrigger()
    func reset()
}

@MainActor
final class SemanticInputController: SuggestionInputStateTracking {
    private(set) var lastSuggestionTriggerKeyAt: Date = .distantPast

    func record(_ event: CapturedInputEvent) {
        guard event.isSuggestionTrigger else {
            return
        }
        lastSuggestionTriggerKeyAt = Date()
        GeometryDebug.log("suggestion-trigger-key kind=\(event.debugName)")
    }

    func clearSuggestionTrigger() {
        lastSuggestionTriggerKeyAt = .distantPast
    }

    func reset() {
        clearSuggestionTrigger()
    }
}
