import AutoCompCore
@testable import AutoCompApp
import XCTest

final class BackendConfigurationHealthCheckTests: XCTestCase {
    func testLocalBackendConfigurationFailsForMissingInstalledModel() throws {
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("missing-\(UUID().uuidString).gguf")
        let settings = CompletionBackendSettings(
            engineKind: .localLlama,
            localModelPath: missingURL.path,
            localRuntimeState: .available
        )

        let check = BackendConfigurationHealthCheck(settings: settings).evaluate()
        let details = try XCTUnwrap(check.details)

        XCTAssertEqual(check.status, .fail)
        XCTAssertEqual(check.summary, "Selected local model is missing.")
        XCTAssertTrue(details.contains(missingURL.lastPathComponent))
        XCTAssertFalse(details.contains(missingURL.deletingLastPathComponent().path))
    }

    func testLocalBackendConfigurationReportsInstalledReadableModel() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoCompHealthLocalModel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        let modelURL = directory.appendingPathComponent("installed.gguf")
        try Data("model".utf8).write(to: modelURL)
        let settings = CompletionBackendSettings(
            engineKind: .localLlama,
            localModelPath: modelURL.path,
            localRuntimeState: .available
        )

        let check = BackendConfigurationHealthCheck(settings: settings).evaluate()
        let details = try XCTUnwrap(check.details)

        XCTAssertEqual(check.status, .ok)
        XCTAssertEqual(check.summary, "Local completions are configured.")
        XCTAssertTrue(details.contains("installed.gguf"))
        XCTAssertFalse(details.contains(directory.path))
    }
}
