@testable import AutoCompCore
import XCTest

final class CompletionBackendDefaultsTests: XCTestCase {
    func testLocalConfigurationUsesSharedRAMDefault() {
        let configuration = LocalLlamaConfiguration(modelPath: "/tmp/model.gguf")

        XCTAssertEqual(configuration.maxRAMBytes, CompletionBackendDefaults.localMaxRAMBytes)
    }

    func testRemoteDefaultsDoNotContainAProductEndpoint() {
        XCTAssertTrue(CompletionBackendDefaults.remoteBaseURL.isEmpty)
        XCTAssertEqual(CompletionBackendDefaults.remoteModel, "default")
        XCTAssertEqual(CompletionBackendDefaults.providerTimeout, .seconds(30))
    }
}
