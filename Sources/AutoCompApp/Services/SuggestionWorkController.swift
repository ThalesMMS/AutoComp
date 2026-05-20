import Foundation

@MainActor
final class SuggestionWorkController {
    private var latestWorkID = 0
    private var debounceTask: Task<Void, Never>?
    private var generationTask: Task<Void, Never>?

    @discardableResult
    func replaceDebouncedWork(_ operation: @escaping @Sendable (Int) async -> Void) -> Int {
        latestWorkID += 1
        let workID = latestWorkID
        debounceTask?.cancel()
        debounceTask = Task {
            await operation(workID)
        }
        return workID
    }

    @discardableResult
    func replaceGenerationWork(_ operation: @escaping @Sendable (Int) async -> Void) -> Int {
        latestWorkID += 1
        let workID = latestWorkID
        generationTask?.cancel()
        generationTask = Task {
            await operation(workID)
        }
        return workID
    }

    func cancelAll() {
        latestWorkID += 1
        debounceTask?.cancel()
        debounceTask = nil
        generationTask?.cancel()
        generationTask = nil
    }

    func isCurrent(_ workID: Int) -> Bool {
        workID == latestWorkID
    }
}
