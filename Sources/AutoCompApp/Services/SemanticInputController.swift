import Foundation

@MainActor
protocol SuggestionInputStateTracking: AnyObject {
    var lastSuggestionTriggerKeyAt: Date { get }
    func record(_ event: CapturedInputEvent)
    func action(for event: CapturedInputEvent) -> SuggestionInputAction
    func clearSuggestionTrigger()
    func reset()
}

struct SuggestionInputAction: Equatable, Sendable {
    let event: CapturedInputEvent

    var shouldSchedulePrediction: Bool {
        event.shouldSchedulePrediction
    }

    var shouldClearSuggestion: Bool {
        event.shouldClearSuggestion
    }

    var clearEventKind: CapturedInputEventKind? {
        shouldClearSuggestion ? event.eventKind : nil
    }

    var logDescription: String {
        "eventKind=\(event.eventKind.rawValue) kind=\(event.debugName) schedule=\(shouldSchedulePrediction) clear=\(shouldClearSuggestion)"
    }
}

extension SuggestionInputStateTracking {
    func action(for event: CapturedInputEvent) -> SuggestionInputAction {
        record(event)
        return SuggestionInputAction(event: event)
    }
}

@MainActor
final class SuggestionInputController: SuggestionInputStateTracking {
    private(set) var lastSuggestionTriggerKeyAt: Date = .distantPast

    func record(_ event: CapturedInputEvent) {
        guard event.isSuggestionTrigger else {
            return
        }
        lastSuggestionTriggerKeyAt = Date()
        GeometryDebug.log("suggestion-trigger-key eventKind=\(event.eventKind.rawValue) kind=\(event.debugName)")
    }

    func clearSuggestionTrigger() {
        lastSuggestionTriggerKeyAt = .distantPast
    }

    func reset() {
        clearSuggestionTrigger()
    }
}
