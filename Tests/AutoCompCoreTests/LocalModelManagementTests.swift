import AutoCompCore
import XCTest

final class LocalModelManagementTests: XCTestCase {
    func testScannerListsOnlyGGUFModelsWithPreferredOrder() throws {
        let directory = try makeTemporaryDirectory()
        try Data("alpha".utf8).write(to: directory.appendingPathComponent("alpha.gguf"))
        try Data("preferred".utf8).write(to: directory.appendingPathComponent("preferred.gguf"))
        try Data("partial".utf8).write(
            to: directory.appendingPathComponent("partial.gguf.staging-\(UUID().uuidString).gguf")
        )
        try Data("notes".utf8).write(to: directory.appendingPathComponent("notes.txt"))

        let models = try ModelDirectoryScanner().scan(
            directoryURL: directory,
            preferredFilenames: ["preferred.gguf"]
        )

        XCTAssertEqual(models.map(\.filename), ["preferred.gguf", "alpha.gguf"])
        XCTAssertEqual(models.first?.displayName, "preferred.gguf")
    }

    func testValidatorRejectsNonGGUFWithClearMessage() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("model.bin")
        try Data("model".utf8).write(to: url)

        XCTAssertThrowsError(try ModelFileValidator.validateGGUFFile(at: url)) { error in
            XCTAssertEqual(error as? ModelFileValidationError, .invalidExtension("model.bin"))
            XCTAssertTrue(error.localizedDescription.contains(".gguf"))
        }
    }

    func testValidatorChecksSizeAndSHA256() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("model.gguf")
        try Data("hello".utf8).write(to: url)

        XCTAssertNoThrow(try ModelFileValidator.validateGGUFFile(
            at: url,
            expectedBytes: 5,
            expectedSHA256: "2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824"
        ))
        XCTAssertThrowsError(try ModelFileValidator.validateGGUFFile(at: url, expectedBytes: 99)) { error in
            XCTAssertEqual(error as? ModelFileValidationError, .sizeMismatch(expected: 99, actual: 5))
            XCTAssertTrue(error.localizedDescription.contains("incomplete"))
        }
        XCTAssertThrowsError(try ModelFileValidator.validateGGUFFile(
            at: url,
            expectedSHA256: String(repeating: "0", count: 64)
        )) { error in
            guard case .checksumMismatch = error as? ModelFileValidationError else {
                return XCTFail("Expected checksum mismatch, got \(error)")
            }
            XCTAssertTrue(error.localizedDescription.contains("checksum"))
        }
    }

    func testDownloadFileRescuerMovesAndCleansTemporaryFile() throws {
        let directory = try makeTemporaryDirectory()
        let sourceURL = directory.appendingPathComponent("download.tmp")
        try Data("download".utf8).write(to: sourceURL)

        let rescuedURL = try DownloadFileRescuer.rescue(temporaryFileAt: sourceURL)

        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: rescuedURL.path))

        DownloadFileRescuer.cleanup(holdingFileAt: rescuedURL)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rescuedURL.path))
    }

    @MainActor
    func testFailedStagedDownloadPreservesExistingModel() throws {
        let directory = try makeTemporaryDirectory()
        let existingURL = directory.appendingPathComponent("demo.gguf")
        let temporaryURL = directory.appendingPathComponent("partial.gguf")
        try Data("existing model".utf8).write(to: existingURL)
        try Data("partial".utf8).write(to: temporaryURL)

        let model = DownloadableLocalModel(
            filename: "demo.gguf",
            displayName: "Demo",
            downloadURL: URL(string: "https://example.com/demo.gguf")!,
            approximateSizeInGigabytes: 0.1,
            expectedSizeBytes: 99
        )
        let manager = ModelDownloadManager(
            catalog: LocalModelCatalog(downloadableModels: [model]),
            modelsDirectoryURL: directory,
            downloader: StubModelDownloader(temporaryURL: temporaryURL)
        )

        XCTAssertThrowsError(try manager.installDownloadedFile(model, temporaryURL: temporaryURL)) { error in
            XCTAssertEqual(error as? ModelFileValidationError, .sizeMismatch(expected: 99, actual: 7))
        }
        XCTAssertEqual(try String(contentsOf: existingURL, encoding: .utf8), "existing model")
        let remainingFiles = try FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertFalse(remainingFiles.contains { $0.contains(".staging-") })
    }

    @MainActor
    func testDownloadPublishesProgressWhileRunning() async throws {
        let directory = try makeTemporaryDirectory()
        let temporaryURL = directory.appendingPathComponent("download.gguf")
        try Data("downloaded model".utf8).write(to: temporaryURL)

        let model = DownloadableLocalModel(
            filename: "demo.gguf",
            displayName: "Demo",
            downloadURL: URL(string: "https://example.com/demo.gguf")!,
            approximateSizeInGigabytes: 0.1
        )
        let downloader = PausingModelDownloader(temporaryURL: temporaryURL)
        let manager = ModelDownloadManager(
            catalog: LocalModelCatalog(downloadableModels: [model]),
            modelsDirectoryURL: directory,
            downloader: downloader
        )

        let task = Task { @MainActor in
            await manager.downloadAndWait(model)
        }

        await downloader.waitUntilStarted()
        XCTAssertEqual(manager.state(for: model), .loading(progress: 0.42))

        manager.refreshModelStates()
        XCTAssertEqual(manager.state(for: model), .loading(progress: 0.42))

        await downloader.finish()
        await task.value

        XCTAssertEqual(manager.state(for: model), .ready)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.appendingPathComponent("demo.gguf").path))
    }

    @MainActor
    func testFailedDownloadStateSurvivesRefreshForRetryVisibility() async throws {
        let directory = try makeTemporaryDirectory()
        let model = DownloadableLocalModel(
            filename: "demo.gguf",
            displayName: "Demo",
            downloadURL: URL(string: "https://example.com/demo.gguf")!,
            approximateSizeInGigabytes: 0.1
        )
        let manager = ModelDownloadManager(
            catalog: LocalModelCatalog(downloadableModels: [model]),
            modelsDirectoryURL: directory,
            downloader: FailingModelDownloader(error: ModelDownloadError.httpStatus(404))
        )

        await manager.downloadAndWait(model)
        manager.refreshModelStates()

        guard case .failed(let message) = manager.state(for: model) else {
            return XCTFail("Expected failed state, got \(manager.state(for: model))")
        }
        XCTAssertTrue(message.contains("HTTP 404"))
    }

    @MainActor
    func testRuntimeBootstrapStateReflectsScannedModels() throws {
        let directory = try makeTemporaryDirectory()
        let bootstrap = RuntimeBootstrapModel(
            modelsDirectoryURL: directory,
            preferredFilenames: ["model.gguf"]
        )

        XCTAssertEqual(bootstrap.state, .idle)
        XCTAssertTrue(bootstrap.availableModels.isEmpty)

        let modelURL = directory.appendingPathComponent("model.gguf")
        try Data("model".utf8).write(to: modelURL)

        bootstrap.refreshAvailableModels()

        XCTAssertEqual(bootstrap.state, .ready("1 local model ready"))
        XCTAssertEqual(bootstrap.selectedModel(for: modelURL.path)?.filename, "model.gguf")
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("AutoCompLocalModelTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return directory
    }
}

private struct StubModelDownloader: ModelFileDownloading {
    let temporaryURL: URL
    var responseStatusCode: Int? = 200

    func download(
        from url: URL,
        progress: @escaping ModelDownloadProgressHandler
    ) async throws -> ModelDownloadResult {
        ModelDownloadResult(temporaryURL: temporaryURL, responseStatusCode: responseStatusCode)
    }
}

private actor PausingModelDownloader: ModelFileDownloading {
    let temporaryURL: URL
    private var isStarted = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var finishContinuation: CheckedContinuation<Void, Never>?

    init(temporaryURL: URL) {
        self.temporaryURL = temporaryURL
    }

    func download(
        from url: URL,
        progress: @escaping ModelDownloadProgressHandler
    ) async throws -> ModelDownloadResult {
        await progress(0.42)
        markStarted()
        await withCheckedContinuation { continuation in
            finishContinuation = continuation
        }
        return ModelDownloadResult(temporaryURL: temporaryURL, responseStatusCode: 200)
    }

    func waitUntilStarted() async {
        if isStarted {
            return
        }
        await withCheckedContinuation { continuation in
            startedWaiters.append(continuation)
        }
    }

    func finish() {
        finishContinuation?.resume()
        finishContinuation = nil
    }

    private func markStarted() {
        isStarted = true
        let waiters = startedWaiters
        startedWaiters = []
        for waiter in waiters {
            waiter.resume()
        }
    }
}

private struct FailingModelDownloader: ModelFileDownloading {
    let error: Error

    func download(
        from url: URL,
        progress: @escaping ModelDownloadProgressHandler
    ) async throws -> ModelDownloadResult {
        throw error
    }
}
