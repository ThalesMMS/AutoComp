import AutoCompCore
import CryptoKit
import Foundation
import OSLog

struct AutoCompDebugOptions: Codable, Equatable, Sendable {
    var localDebugOptIn: Bool

    init(localDebugOptIn: Bool = false) {
        self.localDebugOptIn = localDebugOptIn
    }

    static let normal = AutoCompDebugOptions()

    var allowsSensitiveDebug: Bool {
        localDebugOptIn
    }

    var allowsSensitivePromptPreview: Bool {
        localDebugOptIn
    }
}

final class AutoCompDebugOptionsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "debugOptions"
    ) {
        self.defaults = defaults
        self.key = key
    }

    func load() -> AutoCompDebugOptions {
        if ProcessInfo.processInfo.environment["AUTOCOMP_LOCAL_DEBUG_OPT_IN"] == "1" {
            return AutoCompDebugOptions(localDebugOptIn: true)
        }

        guard let data = defaults.data(forKey: key),
              let options = try? JSONDecoder().decode(AutoCompDebugOptions.self, from: data) else {
            return .normal
        }
        return options
    }

    func save(_ options: AutoCompDebugOptions) {
        guard let data = try? JSONEncoder().encode(options) else {
            return
        }
        defaults.set(data, forKey: key)
    }
}

struct RedactedTextSummary: Equatable, CustomStringConvertible, Sendable {
    let characterCount: Int
    let utf8ByteCount: Int
    let sha256Prefix: String

    var description: String {
        "chars=\(characterCount) bytes=\(utf8ByteCount) sha256=\(sha256Prefix)"
    }
}

struct AutoCompLogger: Sendable {
    private let logger: Logger

    init(category: String) {
        self.logger = Logger(subsystem: "com.autocomp.AutoComp", category: category)
    }

    func info(_ message: @autoclosure () -> String) {
        let resolvedMessage = message()
        logger.info("\(resolvedMessage, privacy: .public)")
    }

    func error(_ message: @autoclosure () -> String) {
        let resolvedMessage = message()
        logger.error("\(resolvedMessage, privacy: .public)")
    }

    static func redactedSummary(for text: String) -> RedactedTextSummary {
        let digest = SHA256.hash(data: Data(text.utf8))
        let prefix = digest
            .prefix(8)
            .map { String(format: "%02x", $0) }
            .joined()
        return RedactedTextSummary(
            characterCount: text.count,
            utf8ByteCount: text.utf8.count,
            sha256Prefix: prefix
        )
    }
}

struct DebugArtifactStore {
    let directory: URL
    private let fileManager: FileManager

    init(
        directory: URL = DebugArtifactStore.defaultDirectory,
        fileManager: FileManager = .default
    ) {
        self.directory = directory
        self.fileManager = fileManager
    }

    @discardableResult
    func saveSensitiveArtifact(
        named name: String,
        contents: String,
        options: AutoCompDebugOptions,
        createdAt: Date = Date()
    ) throws -> URL? {
        guard options.allowsSensitiveDebug else {
            return nil
        }

        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = "\(timestamp(createdAt))-\(sanitized(name)).txt"
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        let body = """
        AutoComp local debug artifact.
        This file may contain prompt, OCR, clipboard, or typed user content.
        Delete it from Settings > Privacy when debugging is complete.

        \(contents)
        """
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @discardableResult
    func saveRedactedArtifact(
        named name: String,
        data: Data,
        fileExtension: String = "json",
        createdAt: Date = Date()
    ) throws -> URL {
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let filename = "\(timestamp(createdAt))-\(sanitized(name)).\(sanitized(fileExtension))"
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        try data.write(to: url, options: [.atomic])
        return url
    }

    func deleteAll() throws {
        guard fileManager.fileExists(atPath: directory.path) else {
            return
        }
        try fileManager.removeItem(at: directory)
    }

    @discardableResult
    func exportDebugLogs(
        to destinationDirectory: URL,
        options: AutoCompDebugOptions,
        createdAt: Date = Date()
    ) throws -> URL {
        let exportDirectory = destinationDirectory
            .appendingPathComponent("AutoComp-Debug-Logs-\(timestamp(createdAt))", isDirectory: true)
        try fileManager.createDirectory(at: exportDirectory, withIntermediateDirectories: true)

        let artifacts = artifactURLs()
        let summary = """
        AutoComp local debug log export.
        Created: \(timestamp(createdAt))
        Sensitive debug artifacts enabled: \(options.allowsSensitiveDebug ? "yes" : "no")
        Debug artifact count: \(artifacts.count)
        Debug artifact source: \(directory.path)

        This export is local. Review files before attaching them to a report.
        """
        try summary.write(
            to: exportDirectory.appendingPathComponent("debug-summary.txt", isDirectory: false),
            atomically: true,
            encoding: .utf8
        )

        guard !artifacts.isEmpty else {
            return exportDirectory
        }

        let artifactsDirectory = exportDirectory.appendingPathComponent("DebugArtifacts", isDirectory: true)
        try fileManager.createDirectory(at: artifactsDirectory, withIntermediateDirectories: true)
        for artifact in artifacts {
            let destination = artifactsDirectory.appendingPathComponent(
                artifact.lastPathComponent,
                isDirectory: artifact.hasDirectoryPath
            )
            try fileManager.copyItem(at: artifact, to: destination)
        }

        return exportDirectory
    }

    func artifactCount() -> Int {
        artifactURLs().count
    }

    var directoryPath: String {
        directory.path
    }

    private func artifactURLs() -> [URL] {
        guard let urls = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }
        return urls.filter { !$0.hasDirectoryPath }
    }

    private func sanitized(_ name: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = name.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return collapsed.isEmpty ? "artifact" : collapsed
    }

    private func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: ".", with: "-")
    }

    static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AutoComp", isDirectory: true)
            .appendingPathComponent("DebugArtifacts", isDirectory: true)
    }
}

struct SuggestionDebugLogger {
    private let logger = AutoCompLogger(category: "suggestion-debug")
    private let artifactStore: DebugArtifactStore

    init(artifactStore: DebugArtifactStore) {
        self.artifactStore = artifactStore
    }

    func recordPlaygroundResult(
        _ result: CompletionPlaygroundResult,
        options: AutoCompDebugOptions
    ) {
        let promptSummary = AutoCompLogger.redactedSummary(for: result.preview.request.prompt)
        let rawSummary = AutoCompLogger.redactedSummary(for: result.rawOutput)
        let normalizedSummary = AutoCompLogger.redactedSummary(for: result.normalizedOutput)
        logger.info("playground-completion prompt=\(promptSummary) raw=\(rawSummary) normalized=\(normalizedSummary) latencyMs=\(result.latencyMs)")

        guard options.allowsSensitiveDebug else {
            return
        }

        let contents = """
        Prompt:
        \(result.preview.request.prompt)

        Raw output:
        \(result.rawOutput)

        Normalized output:
        \(result.normalizedOutput)
        """
        do {
            _ = try artifactStore.saveSensitiveArtifact(
                named: "playground-completion",
                contents: contents,
                options: options
            )
        } catch {
            logger.error("debug-artifact-save-failed reason=\(String(describing: error))")
        }
    }

    func recordPlaygroundPreview(
        _ preview: CompletionPlaygroundPreview,
        options: AutoCompDebugOptions
    ) {
        let promptSummary = AutoCompLogger.redactedSummary(for: preview.request.prompt)
        logger.info("playground-preview prompt=\(promptSummary) mode=\(preview.modeTitle)")

        guard options.allowsSensitiveDebug else {
            return
        }

        do {
            _ = try artifactStore.saveSensitiveArtifact(
                named: "playground-preview",
                contents: preview.request.prompt,
                options: options
            )
        } catch {
            logger.error("debug-artifact-save-failed reason=\(String(describing: error))")
        }
    }

    func recordAutocomplete(
        id: UUID = UUID(),
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?,
        clipboardContext: ClipboardContextSnapshot?,
        invocation: String,
        outcome: String,
        suggestions: [Suggestion],
        publishedSuggestion: Suggestion?,
        rejectionReason: String?,
        discardReason: String?,
        errorDescription: String?,
        routingPolicy: CompletionRoutingPolicy?,
        options: AutoCompDebugOptions
    ) {
        let request = CompletionRequestFactory().makeRequest(
            for: context,
            configuration: RemoteCompletionConfiguration(
                baseURL: "debug://autocomplete",
                apiKey: "",
                model: routingPolicy?.activeKind.rawValue ?? "debug"
            ),
            privacySettings: privacySettings,
            visualContext: visualContext,
            clipboardContext: clipboardContext
        )
        let promptSummary = AutoCompLogger.redactedSummary(for: request.prompt)
        let rawSummary = AutoCompLogger.redactedSummary(
            for: suggestions.map { $0.rawText ?? "" }.joined(separator: "\n---\n")
        )
        let normalizedSummary = AutoCompLogger.redactedSummary(
            for: suggestions.map(\.visibleText).joined(separator: "\n---\n")
        )
        let captureDiagnostics = ContextCaptureDiagnostics(
            context: context,
            visualContext: visualContext,
            clipboardContext: clipboardContext
        )
        logger.info("autocomplete id=\(id.uuidString) invocation=\(invocation) outcome=\(outcome) source=\(captureDiagnostics.contextSourceLogValue) geometry=\(captureDiagnostics.geometryQualityLogValue) trust=\(captureDiagnostics.trustTitle) supplemental=\(captureDiagnostics.supplementalSourceLogValue) visualContext=\(captureDiagnostics.visualContextLogValue) clipboardContext=\(captureDiagnostics.clipboardContextLogValue) prompt=\(promptSummary) raw=\(rawSummary) normalized=\(normalizedSummary)")

        guard options.allowsSensitiveDebug else {
            return
        }

        let contents = """
        Autocomplete debug id: \(id.uuidString)
        Invocation: \(invocation)
        Outcome: \(outcome)
        Rejection reason: \(rejectionReason ?? "none")
        Discard reason: \(discardReason ?? "none")
        Error: \(errorDescription ?? "none")
        Requested backend: \(routingPolicy?.activeKind.displayName ?? "unknown")
        Fallback backend: \(routingPolicy?.fallbackKind?.displayName ?? "none")

        App: \(context.app.displayName)
        Bundle ID: \(context.app.bundleID)
        Domain: \(context.domain ?? "none")
        Focused element ID: \(context.focusedElementID)
        Capture sources: \(captureDiagnostics.contextSourceTitle)
        Geometry quality: \(captureDiagnostics.geometryQualityTitle)
        Context trust: \(captureDiagnostics.trustTitle)
        Context warning: \(captureDiagnostics.lowTrustWarning ?? "none")
        Supplemental sources: \(captureDiagnostics.supplementalSourceTitle)

        Request mode: \(request.mode.rawValue)
        FIM suffix injected: \(request.fimSuffixInjected)
        Prompt:
        \(request.prompt)

        Visual context:
        \(visualContext?.summary ?? "none")

        Clipboard context:
        \(clipboardContext?.promptPreview ?? "none")

        Suggestions:
        \(suggestionsDescription(suggestions))

        Published suggestion:
        \(publishedSuggestionDescription(publishedSuggestion))
        """

        do {
            _ = try artifactStore.saveSensitiveArtifact(
                named: "autocomplete-\(outcome)",
                contents: contents,
                options: options
            )
        } catch {
            logger.error("debug-artifact-save-failed reason=\(String(describing: error))")
        }
    }

    private func suggestionsDescription(_ suggestions: [Suggestion]) -> String {
        guard !suggestions.isEmpty else {
            return "none"
        }

        return suggestions.enumerated().map { index, suggestion in
            """
            [\(index)]
            Raw:
            \(suggestion.rawText ?? "none")
            Visible:
            \(suggestion.visibleText)
            Remaining:
            \(suggestion.remainingText)
            Latency ms: \(suggestion.latencyMs)
            """
        }.joined(separator: "\n\n")
    }

    private func publishedSuggestionDescription(_ suggestion: Suggestion?) -> String {
        guard let suggestion else {
            return "none"
        }

        return """
        Raw:
        \(suggestion.rawText ?? "none")
        Visible:
        \(suggestion.visibleText)
        Remaining:
        \(suggestion.remainingText)
        Latency ms: \(suggestion.latencyMs)
        """
    }
}
