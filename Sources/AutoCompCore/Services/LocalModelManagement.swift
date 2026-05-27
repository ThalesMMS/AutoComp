import Combine
import CryptoKit
import Foundation

public struct LocalModelOption: Equatable, Hashable, Identifiable, Sendable {
    public let filename: String
    public let url: URL
    public let byteCount: Int64?

    public init(filename: String, url: URL, byteCount: Int64? = nil) {
        self.filename = filename
        self.url = url
        self.byteCount = byteCount
    }

    public var id: String { url.path }

    public var displayName: String {
        LocalModelCatalog.displayName(for: filename)
    }

    public var sizeLabel: String {
        guard let byteCount else {
            return "Unknown size"
        }

        return ByteCountFormatter.string(fromByteCount: byteCount, countStyle: .file)
    }
}

public struct DownloadableLocalModel: Equatable, Hashable, Identifiable, Sendable {
    public let filename: String
    public let displayName: String
    public let downloadURL: URL
    public let approximateSizeInGigabytes: Double
    public let expectedSizeBytes: Int64?
    public let sha256: String?
    public let alternateFilenames: [String]

    public init(
        filename: String,
        displayName: String,
        downloadURL: URL,
        approximateSizeInGigabytes: Double,
        expectedSizeBytes: Int64? = nil,
        sha256: String? = nil,
        alternateFilenames: [String] = []
    ) {
        self.filename = filename
        self.displayName = displayName
        self.downloadURL = downloadURL
        self.approximateSizeInGigabytes = approximateSizeInGigabytes
        self.expectedSizeBytes = expectedSizeBytes
        self.sha256 = sha256
        self.alternateFilenames = alternateFilenames
    }

    public var id: String { filename }

    public var approximateSizeLabel: String {
        String(format: "~%.1f GB", approximateSizeInGigabytes)
    }

    public var allKnownFilenames: [String] {
        [filename] + alternateFilenames
    }
}

public struct LocalModelCatalog: Equatable, Sendable {
    public let downloadableModels: [DownloadableLocalModel]

    public init(downloadableModels: [DownloadableLocalModel]) {
        self.downloadableModels = downloadableModels
    }

    public static let recommended = LocalModelCatalog(downloadableModels: [
        DownloadableLocalModel(
            filename: "Qwen3-0.6B-Q4_K_M.gguf",
            displayName: "Qwen3 0.6B Q4",
            downloadURL: URL(
                string: "https://huggingface.co/unsloth/Qwen3-0.6B-GGUF/resolve/main/Qwen3-0.6B-Q4_K_M.gguf?download=true"
            )!,
            approximateSizeInGigabytes: 0.4,
            expectedSizeBytes: 396_705_472,
            sha256: "ac2d97712095a558e31573f62f466a3f9d93990898b0ec79d7c974c1780d524a"
        ),
        DownloadableLocalModel(
            filename: "gemma-4-E2B-it-Q4_K_M.gguf",
            displayName: "Gemma 4 E2B Q4",
            downloadURL: URL(
                string: "https://huggingface.co/unsloth/gemma-4-E2B-it-GGUF/resolve/main/gemma-4-E2B-it-Q4_K_M.gguf?download=true"
            )!,
            approximateSizeInGigabytes: 3.1,
            expectedSizeBytes: 3_106_736_256,
            sha256: "9378bc471710229ef165709b62e34bfb62231420ddaf6d729e727305b5b8672d"
        )
    ])

    public static var defaultModelsDirectoryURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AutoComp", isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true)
    }

    public static var preferredFilenames: [String] {
        recommended.downloadableModels.map(\.filename)
    }

    public static func displayName(for filename: String) -> String {
        switch filename {
        case "Qwen3-0.6B-Q4_K_M.gguf":
            return "Qwen3 0.6B Q4"
        case "gemma-4-E2B-it-Q4_K_M.gguf":
            return "Gemma 4 E2B Q4"
        default:
            return filename
        }
    }
}

public enum ModelDirectoryScannerError: LocalizedError, Equatable, Sendable {
    case notDirectory(String)
    case unreadable(String)

    public var errorDescription: String? {
        switch self {
        case .notDirectory(let path):
            return "The model location is not a directory: \(path)"
        case .unreadable(let path):
            return "Could not read local models from \(path)."
        }
    }
}

public struct ModelDirectoryScanner: Sendable {
    public init() {}

    public func scan(
        directoryURL: URL,
        preferredFilenames: [String] = LocalModelCatalog.preferredFilenames
    ) throws -> [LocalModelOption] {
        let fileManager = FileManager.default
        var isDirectory = ObjCBool(false)
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory) else {
            return []
        }
        guard isDirectory.boolValue else {
            throw ModelDirectoryScannerError.notDirectory(directoryURL.path)
        }

        let fileURLs: [URL]
        do {
            fileURLs = try fileManager.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: [.fileSizeKey],
                options: [.skipsHiddenFiles]
            )
        } catch {
            throw ModelDirectoryScannerError.unreadable(directoryURL.path)
        }

        let options = fileURLs
            .filter { $0.pathExtension.caseInsensitiveCompare("gguf") == .orderedSame }
            .filter { !$0.lastPathComponent.contains(".staging-") }
            .map { url in
                let byteCount = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize)
                    .map(Int64.init)
                return LocalModelOption(
                    filename: url.lastPathComponent,
                    url: url,
                    byteCount: byteCount
                )
            }

        return ordered(options: options, preferredFilenames: preferredFilenames)
    }

    private func ordered(
        options: [LocalModelOption],
        preferredFilenames: [String]
    ) -> [LocalModelOption] {
        let byFilename = Dictionary(uniqueKeysWithValues: options.map { ($0.filename, $0) })
        var ordered: [LocalModelOption] = []
        var seen = Set<String>()

        for filename in preferredFilenames {
            guard let option = byFilename[filename],
                  seen.insert(filename).inserted else {
                continue
            }
            ordered.append(option)
        }

        for option in options.sorted(by: {
            $0.filename.localizedCaseInsensitiveCompare($1.filename) == .orderedAscending
        }) {
            guard seen.insert(option.filename).inserted else {
                continue
            }
            ordered.append(option)
        }

        return ordered
    }
}

public enum ModelFileValidationError: LocalizedError, Equatable, Sendable {
    case invalidExtension(String)
    case emptyFile(String)
    case fileUnreadable(String)
    case sizeMismatch(expected: Int64, actual: Int64)
    case checksumMismatch(expected: String, actual: String)

    public var errorDescription: String? {
        switch self {
        case .invalidExtension(let filename):
            return "Choose a .gguf model file. \(filename) is not supported."
        case .emptyFile(let path):
            return "The model file is empty: \(path)"
        case .fileUnreadable(let path):
            return "Could not read the model file at \(path)."
        case .sizeMismatch(let expected, let actual):
            return "Downloaded model is \(actual) bytes; expected \(expected). The download may be incomplete."
        case .checksumMismatch(let expected, let actual):
            let expectedPrefix = String(expected.lowercased().prefix(16))
            let actualPrefix = String(actual.lowercased().prefix(16))
            return "Downloaded model checksum \(actualPrefix) does not match expected \(expectedPrefix)."
        }
    }
}

public enum ModelFileValidator {
    public static func validateGGUFFile(
        at url: URL,
        expectedBytes: Int64? = nil,
        expectedSHA256: String? = nil
    ) throws {
        try validateExtension(of: url)
        try validateSize(of: url, expectedBytes: expectedBytes)
        try validateSHA256(of: url, expectedSHA256: expectedSHA256)
    }

    public static func validateExtension(of url: URL) throws {
        guard url.pathExtension.caseInsensitiveCompare("gguf") == .orderedSame else {
            throw ModelFileValidationError.invalidExtension(url.lastPathComponent)
        }
    }

    public static func validateSize(of url: URL, expectedBytes: Int64?) throws {
        let actualBytes = try fileSize(of: url)
        if actualBytes == 0 {
            throw ModelFileValidationError.emptyFile(url.path)
        }
        if let expectedBytes, actualBytes != expectedBytes {
            throw ModelFileValidationError.sizeMismatch(expected: expectedBytes, actual: actualBytes)
        }
    }

    public static func validateSHA256(of url: URL, expectedSHA256: String?) throws {
        guard let expectedSHA256 else {
            return
        }
        let actualSHA256 = try sha256Hex(of: url)
        guard actualSHA256.lowercased() == expectedSHA256.lowercased() else {
            throw ModelFileValidationError.checksumMismatch(expected: expectedSHA256, actual: actualSHA256)
        }
    }

    private static func fileSize(of url: URL) throws -> Int64 {
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard let size = attributes[.size] as? NSNumber else {
                throw ModelFileValidationError.fileUnreadable(url.path)
            }
            return size.int64Value
        } catch let error as ModelFileValidationError {
            throw error
        } catch {
            throw ModelFileValidationError.fileUnreadable(url.path)
        }
    }

    private static func sha256Hex(of url: URL) throws -> String {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ModelFileValidationError.fileUnreadable(url.path)
        }
        defer {
            try? handle.close()
        }

        var hasher = SHA256()
        while true {
            let chunk: Data
            do {
                chunk = try handle.read(upToCount: 1024 * 1024) ?? Data()
            } catch {
                throw ModelFileValidationError.fileUnreadable(url.path)
            }
            if chunk.isEmpty {
                break
            }
            hasher.update(data: chunk)
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum DownloadFileRescuer {
    public static func rescue(
        temporaryFileAt location: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        let holdingURL = fileManager.temporaryDirectory
            .appendingPathComponent("AutoComp-download-\(UUID().uuidString)", isDirectory: false)
        try fileManager.moveItem(at: location, to: holdingURL)
        return holdingURL
    }

    public static func cleanup(
        holdingFileAt url: URL,
        fileManager: FileManager = .default
    ) {
        try? fileManager.removeItem(at: url)
    }
}

public enum DownloadOutcomeClassifier {
    public static func isUserCancellation(_ error: Error) -> Bool {
        if error is CancellationError {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .cancelled {
            return true
        }
        return false
    }
}

public enum ModelDownloadState: Equatable, Sendable {
    case idle
    case loading(progress: Double?)
    case ready
    case failed(String)

    public var statusText: String {
        switch self {
        case .idle:
            return "Not installed"
        case .loading(let progress):
            if let progress {
                return "Downloading \(Int((progress * 100).rounded()))%"
            }
            return "Downloading"
        case .ready:
            return "Installed"
        case .failed(let message):
            return message
        }
    }

    public var isLoading: Bool {
        if case .loading = self {
            return true
        }
        return false
    }
}

public struct ModelDownloadResult: Sendable {
    public let temporaryURL: URL
    public let responseStatusCode: Int?

    public init(temporaryURL: URL, responseStatusCode: Int? = nil) {
        self.temporaryURL = temporaryURL
        self.responseStatusCode = responseStatusCode
    }
}

public typealias ModelDownloadProgressHandler = @MainActor @Sendable (Double?) -> Void

public protocol ModelFileDownloading: Sendable {
    func download(
        from url: URL,
        progress: @escaping ModelDownloadProgressHandler
    ) async throws -> ModelDownloadResult
}

public extension ModelFileDownloading {
    func download(from url: URL) async throws -> ModelDownloadResult {
        try await download(from: url, progress: { _ in })
    }
}

public struct URLSessionModelFileDownloader: ModelFileDownloading {
    public init() {}

    public func download(
        from url: URL,
        progress: @escaping ModelDownloadProgressHandler
    ) async throws -> ModelDownloadResult {
        let delegate = URLSessionDownloadProgressDelegate(progress: progress)
        let (temporaryURL, response) = try await URLSession.shared.download(from: url, delegate: delegate)
        await progress(1)
        let rescuedURL = try DownloadFileRescuer.rescue(temporaryFileAt: temporaryURL)
        return ModelDownloadResult(
            temporaryURL: rescuedURL,
            responseStatusCode: (response as? HTTPURLResponse)?.statusCode
        )
    }
}

private final class URLSessionDownloadProgressDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let progress: ModelDownloadProgressHandler
    private let lock = NSLock()
    private var lastReportedProgress: Double = -1

    init(progress: @escaping ModelDownloadProgressHandler) {
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        guard totalBytesExpectedToWrite > 0 else {
            Task { @MainActor [progress] in
                progress(nil)
            }
            return
        }

        let fraction = min(max(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 0), 1)
        guard shouldReport(fraction) else {
            return
        }

        Task { @MainActor [progress] in
            progress(fraction)
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {}

    private func shouldReport(_ fraction: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard fraction == 1 || lastReportedProgress < 0 || fraction - lastReportedProgress >= 0.01 else {
            return false
        }

        lastReportedProgress = fraction
        return true
    }
}

public enum ModelDownloadError: LocalizedError, Equatable, Sendable {
    case httpStatus(Int)
    case promotionFailed(String)

    public var errorDescription: String? {
        switch self {
        case .httpStatus(let statusCode):
            return "Model download failed with HTTP \(statusCode)."
        case .promotionFailed(let path):
            return "Could not install the downloaded model at \(path)."
        }
    }
}

@MainActor
public final class ModelDownloadManager: ObservableObject {
    @Published public private(set) var modelStates: [String: ModelDownloadState] = [:]

    public var onModelDirectoryChanged: (() -> Void)?

    private let catalog: LocalModelCatalog
    private let modelsDirectoryURL: URL
    private let downloader: any ModelFileDownloading
    private var activeDownloads = Set<String>()
    private var downloadTasks: [String: Task<Void, Never>] = [:]

    public init(
        catalog: LocalModelCatalog = .recommended,
        modelsDirectoryURL: URL = LocalModelCatalog.defaultModelsDirectoryURL,
        downloader: any ModelFileDownloading = URLSessionModelFileDownloader()
    ) {
        self.catalog = catalog
        self.modelsDirectoryURL = modelsDirectoryURL
        self.downloader = downloader
        refreshModelStates()
    }

    public var models: [DownloadableLocalModel] {
        catalog.downloadableModels
    }

    public var modelsDirectoryPath: String {
        modelsDirectoryURL.path
    }

    public var modelsDirectory: URL {
        modelsDirectoryURL
    }

    public func state(for model: DownloadableLocalModel) -> ModelDownloadState {
        modelStates[model.filename] ?? .idle
    }

    public func refreshModelStates() {
        for model in models {
            if activeDownloads.contains(model.filename) {
                if case .loading(let progress) = modelStates[model.filename] {
                    modelStates[model.filename] = .loading(progress: progress)
                } else {
                    modelStates[model.filename] = .loading(progress: nil)
                }
            } else if installedModelURL(for: model) != nil {
                modelStates[model.filename] = .ready
            } else if case .failed = modelStates[model.filename] {
                continue
            } else {
                modelStates[model.filename] = .idle
            }
        }
    }

    public func download(_ model: DownloadableLocalModel) {
        guard activeDownloads.insert(model.filename).inserted else {
            return
        }

        if installedModelURL(for: model) != nil {
            activeDownloads.remove(model.filename)
            modelStates[model.filename] = .ready
            return
        }

        modelStates[model.filename] = .loading(progress: nil)
        let task = Task { [weak self] in
            guard let self else {
                return
            }
            await self.performDownload(model)
        }
        downloadTasks[model.filename] = task
        if !activeDownloads.contains(model.filename) {
            downloadTasks[model.filename] = nil
        }
    }

    public func downloadAndWait(_ model: DownloadableLocalModel) async {
        guard activeDownloads.insert(model.filename).inserted else {
            return
        }

        modelStates[model.filename] = .loading(progress: nil)
        await performDownload(model)
    }

    public func cancel(filename: String) {
        downloadTasks[filename]?.cancel()
    }

    public func modelFileURL(for model: DownloadableLocalModel) -> URL {
        modelsDirectoryURL.appendingPathComponent(model.filename, isDirectory: false)
    }

    public func installedModelURL(for model: DownloadableLocalModel) -> URL? {
        for filename in model.allKnownFilenames {
            let url = modelsDirectoryURL.appendingPathComponent(filename, isDirectory: false)
            if FileManager.default.fileExists(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    public func installDownloadedFile(
        _ model: DownloadableLocalModel,
        temporaryURL: URL
    ) throws {
        try ensureModelsDirectoryExists()
        let destinationURL = modelFileURL(for: model)
        let stagingURL = modelsDirectoryURL.appendingPathComponent(
            "\(model.filename).staging-\(UUID().uuidString).gguf",
            isDirectory: false
        )

        do {
            try FileManager.default.moveItem(at: temporaryURL, to: stagingURL)
            try ModelFileValidator.validateGGUFFile(
                at: stagingURL,
                expectedBytes: model.expectedSizeBytes,
                expectedSHA256: model.sha256
            )
            try promote(stagingURL: stagingURL, destinationURL: destinationURL)
        } catch {
            try? FileManager.default.removeItem(at: stagingURL)
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
    }

    private func performDownload(_ model: DownloadableLocalModel) async {
        defer {
            activeDownloads.remove(model.filename)
            downloadTasks[model.filename] = nil
        }

        do {
            let result = try await downloader.download(from: model.downloadURL) { [weak self] progress in
                guard let self, self.activeDownloads.contains(model.filename) else {
                    return
                }
                self.modelStates[model.filename] = .loading(progress: progress)
            }
            try Task.checkCancellation()
            try validateDownloadStatus(result.responseStatusCode)
            try installDownloadedFile(model, temporaryURL: result.temporaryURL)
            modelStates[model.filename] = .ready
            onModelDirectoryChanged?()
        } catch {
            if DownloadOutcomeClassifier.isUserCancellation(error) {
                modelStates[model.filename] = installedModelURL(for: model) == nil ? .idle : .ready
            } else {
                modelStates[model.filename] = .failed(
                    (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                )
            }
        }
    }

    private func validateDownloadStatus(_ statusCode: Int?) throws {
        guard let statusCode else {
            return
        }
        guard (200..<300).contains(statusCode) else {
            throw ModelDownloadError.httpStatus(statusCode)
        }
    }

    private func ensureModelsDirectoryExists() throws {
        try FileManager.default.createDirectory(
            at: modelsDirectoryURL,
            withIntermediateDirectories: true
        )
    }

    private func promote(stagingURL: URL, destinationURL: URL) throws {
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            let replacedURL = try FileManager.default.replaceItemAt(
                destinationURL,
                withItemAt: stagingURL,
                backupItemName: nil,
                options: []
            )
            guard replacedURL != nil else {
                throw ModelDownloadError.promotionFailed(destinationURL.path)
            }
        } else {
            try FileManager.default.moveItem(at: stagingURL, to: destinationURL)
        }
    }
}

public enum RuntimeBootstrapState: Equatable, Sendable {
    case idle
    case loading(String)
    case ready(String)
    case failed(String)

    public var summary: String {
        switch self {
        case .idle:
            return "Idle"
        case .loading(let message),
             .ready(let message),
             .failed(let message):
            return message
        }
    }
}

@MainActor
public final class RuntimeBootstrapModel: ObservableObject {
    @Published public private(set) var state: RuntimeBootstrapState = .idle
    @Published public private(set) var availableModels: [LocalModelOption] = []

    private let modelsDirectoryURL: URL
    private let scanner: ModelDirectoryScanner
    private let preferredFilenames: [String]

    public init(
        modelsDirectoryURL: URL = LocalModelCatalog.defaultModelsDirectoryURL,
        scanner: ModelDirectoryScanner = ModelDirectoryScanner(),
        preferredFilenames: [String] = LocalModelCatalog.preferredFilenames
    ) {
        self.modelsDirectoryURL = modelsDirectoryURL
        self.scanner = scanner
        self.preferredFilenames = preferredFilenames
        refreshAvailableModels()
    }

    public func refreshAvailableModels() {
        state = .loading("Scanning local models")
        do {
            availableModels = try scanner.scan(
                directoryURL: modelsDirectoryURL,
                preferredFilenames: preferredFilenames
            )
            state = availableModels.isEmpty
                ? .idle
                : .ready("\(availableModels.count) local model\(availableModels.count == 1 ? "" : "s") ready")
        } catch {
            availableModels = []
            state = .failed((error as? LocalizedError)?.errorDescription ?? error.localizedDescription)
        }
    }

    public func selectedModel(for path: String) -> LocalModelOption? {
        let selectedPath = URL(fileURLWithPath: path).standardizedFileURL.path
        return availableModels.first {
            $0.url.standardizedFileURL.path == selectedPath
        }
    }
}
