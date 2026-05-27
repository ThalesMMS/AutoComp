import Foundation

@MainActor
final class SuggestionPredictionController {
    let debounceInterval: TimeInterval
    private let workController: SuggestionWorkController

    init(
        debounceInterval: TimeInterval = 0.25,
        workController: SuggestionWorkController = SuggestionWorkController()
    ) {
        self.debounceInterval = debounceInterval
        self.workController = workController
    }

    @discardableResult
    func replaceDebouncedWork(_ operation: @escaping @Sendable (Int) async -> Void) -> Int {
        workController.replaceDebouncedWork(operation)
    }

    @discardableResult
    func replaceGenerationWork(_ operation: @escaping @Sendable (Int) async -> Void) -> Int {
        workController.replaceGenerationWork(operation)
    }

    func cancelAll() {
        workController.cancelAll()
    }

    func isCurrent(_ workID: Int) -> Bool {
        workController.isCurrent(workID)
    }
}
