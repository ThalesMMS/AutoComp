import AutoCompCore
@testable import AutoCompApp
import XCTest

@MainActor
final class LocalLlamaRuntimeStatusStoreTests: XCTestCase {
    func testStaleProviderRecorderCannotOverwriteCurrentRuntimeState() async {
        let store = LocalLlamaRuntimeStatusStore()
        let staleRecorder = store.makeRecorder()
        let currentRecorder = store.makeRecorder()

        await staleRecorder(LocalLlamaRuntimeStatus(state: .loaded, modelPath: "/tmp/old.gguf"))

        XCTAssertEqual(store.status, .unloaded)

        await currentRecorder(LocalLlamaRuntimeStatus(state: .loaded, modelPath: "/tmp/current.gguf"))

        XCTAssertEqual(
            store.status,
            LocalLlamaRuntimeStatus(state: .loaded, modelPath: "/tmp/current.gguf")
        )
    }
}
