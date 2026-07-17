import AutoCompCore
import Foundation

enum SuggestionScheduledWorkOutcome: Equatable, Sendable {
    case ready(elapsedMs: Int)
    case cancelled(elapsedMs: Int)
}

@MainActor
final class SuggestionPredictionController {
    private let workController: SuggestionWorkController

    init(
        workController: SuggestionWorkController = SuggestionWorkController()
    ) {
        self.workController = workController
    }

    @discardableResult
    func replaceDebouncedWork(_ operation: @escaping @Sendable (Int) async -> Void) -> Int {
        workController.replaceDebouncedWork(operation)
    }

    @discardableResult
    func replaceScheduledWork(
        decision: SuggestionSchedulingPolicy.Decision,
        _ operation: @escaping @Sendable (Int, SuggestionScheduledWorkOutcome) async -> Void
    ) -> Int {
        let delayMs = decision.remainingDebounceMs
        return workController.replaceDebouncedWork { workID in
            let startedAt = ContinuousClock.now
            if delayMs > 0 {
                do {
                    try await Task.sleep(nanoseconds: UInt64(delayMs) * 1_000_000)
                } catch {
                    await operation(
                        workID,
                        .cancelled(elapsedMs: max(0, startedAt.duration(to: .now).milliseconds))
                    )
                    return
                }
            }
            guard !Task.isCancelled else {
                await operation(
                    workID,
                    .cancelled(elapsedMs: max(0, startedAt.duration(to: .now).milliseconds))
                )
                return
            }
            await operation(
                workID,
                .ready(elapsedMs: max(0, startedAt.duration(to: .now).milliseconds))
            )
        }
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
