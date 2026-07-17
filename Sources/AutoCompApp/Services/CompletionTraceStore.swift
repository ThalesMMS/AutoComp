import AutoCompCore
import Foundation

/// Writes privacy-safe completion events on a utility queue.
///
/// Callers only enqueue typed records; disk failures and rotation never block or
/// fail the autocomplete path.
final class CompletionTraceStore: CompletionTraceRecording, @unchecked Sendable {
    private let directory: URL
    private let fileManager: FileManager
    private let maximumFileBytes: Int
    private let enablementLock = NSLock()
    private var storedIsEnabled: Bool
    private let queue = DispatchQueue(label: "com.autocomp.completion-traces", qos: .utility)
    private var storedWriteFailureCount = 0

    init(
        directory: URL = CompletionTraceStore.defaultDirectory,
        fileManager: FileManager = .default,
        maximumFileBytes: Int = 1_000_000,
        isEnabled: Bool
    ) {
        self.directory = directory
        self.fileManager = fileManager
        self.maximumFileBytes = max(256, maximumFileBytes)
        self.storedIsEnabled = isEnabled
    }

    func record(_ event: CompletionTraceEvent) {
        guard enablementLock.withLock({ storedIsEnabled }) else {
            return
        }

        queue.async { [self] in
            do {
                try append(event)
            } catch {
                storedWriteFailureCount += 1
            }
        }
    }

    func setEnabled(_ isEnabled: Bool) {
        enablementLock.withLock {
            storedIsEnabled = isEnabled
        }
    }

    func flush() {
        queue.sync {}
    }

    func deleteAll() throws {
        try queue.sync {
            guard fileManager.fileExists(atPath: directory.path) else {
                return
            }
            try fileManager.removeItem(at: directory)
        }
    }

    func export(to exportDirectory: URL) throws {
        try queue.sync {
            let sources = traceFileURLs()
            guard !sources.isEmpty else {
                return
            }
            let destination = exportDirectory.appendingPathComponent("CompletionTraces", isDirectory: true)
            try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
            for source in sources {
                let target = destination.appendingPathComponent(source.lastPathComponent)
                if fileManager.fileExists(atPath: target.path) {
                    try fileManager.removeItem(at: target)
                }
                try fileManager.copyItem(at: source, to: target)
            }
        }
    }

    func events() throws -> [CompletionTraceEvent] {
        try queue.sync {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            return try traceFileURLs().flatMap { url in
                let body = try String(contentsOf: url, encoding: .utf8)
                return try body.split(separator: "\n").map { line in
                    try decoder.decode(CompletionTraceEvent.self, from: Data(line.utf8))
                }
            }
        }
    }

    func writeFailureCount() -> Int {
        queue.sync { storedWriteFailureCount }
    }

    private func append(_ event: CompletionTraceEvent) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        var line = try encoder.encode(event)
        line.append(0x0A)

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try rotateIfNeeded(appendingBytes: line.count)

        let current = currentFileURL
        if fileManager.fileExists(atPath: current.path) {
            let handle = try FileHandle(forWritingTo: current)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } else {
            try line.write(to: current, options: [.atomic])
        }
    }

    private func rotateIfNeeded(appendingBytes: Int) throws {
        let currentSize = (try? currentFileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard currentSize + appendingBytes > maximumFileBytes,
              fileManager.fileExists(atPath: currentFileURL.path) else {
            return
        }

        if fileManager.fileExists(atPath: rotatedFileURL.path) {
            try fileManager.removeItem(at: rotatedFileURL)
        }
        try fileManager.moveItem(at: currentFileURL, to: rotatedFileURL)
    }

    private func traceFileURLs() -> [URL] {
        [rotatedFileURL, currentFileURL].filter { fileManager.fileExists(atPath: $0.path) }
    }

    private var currentFileURL: URL {
        directory.appendingPathComponent("completion-traces.jsonl")
    }

    private var rotatedFileURL: URL {
        directory.appendingPathComponent("completion-traces.1.jsonl")
    }

    static var defaultDirectory: URL {
        AutoCompUserDirectories.appSupportDirectory
            .appendingPathComponent("CompletionTraces", isDirectory: true)
    }
}
