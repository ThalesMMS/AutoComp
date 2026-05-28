import AutoCompCore
import Combine
import Foundation

@MainActor
final class LocalLlamaRuntimeStatusStore: ObservableObject, @unchecked Sendable {
    @Published private(set) var status = LocalLlamaRuntimeStatus.unloaded
    private var activeGeneration = UUID()

    func makeRecorder() -> LocalLlamaRuntimeStatusRecorder {
        let generation = UUID()
        activeGeneration = generation
        return { [weak self] status in
            await self?.record(status, generation: generation)
        }
    }

    func record(_ status: LocalLlamaRuntimeStatus) {
        self.status = status
    }

    private func record(_ status: LocalLlamaRuntimeStatus, generation: UUID) {
        guard generation == activeGeneration else {
            return
        }
        self.status = status
    }
}
