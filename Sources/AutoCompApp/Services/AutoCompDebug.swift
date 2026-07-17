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
    private let defaults: MirroredUserDefaults
    private let key: String

    init(
        defaults: UserDefaults = .standard,
        key: String = "debugOptions"
    ) {
        self.defaults = MirroredUserDefaults(primary: defaults)
        self.key = key
    }

    func load() -> AutoCompDebugOptions {
        if ProcessInfo.processInfo.environment["AUTOCOMP_LOCAL_DEBUG_OPT_IN"] == "1" {
            return AutoCompDebugOptions(localDebugOptIn: true)
        }

        guard let options = defaults.decode(AutoCompDebugOptions.self, forKey: key) else {
            return .normal
        }
        return options
    }

    func save(_ options: AutoCompDebugOptions) {
        try? defaults.encode(options, forKey: key)
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

struct DebugChannel: Sendable {
    enum Privacy: Sendable {
        case redactWholeMessage
        case preRedactedStructured
    }

    let isEnabled: Bool
    private let prefix: String
    private let privacy: Privacy
    private let writesToStandardError: Bool
    private let logger: AutoCompLogger
    private let unredactedSink: (@Sendable (String) -> Void)?

    init(
        category: String,
        prefix: String,
        isEnabled: Bool,
        privacy: Privacy,
        writesToStandardError: Bool = false,
        unredactedSink: (@Sendable (String) -> Void)? = nil
    ) {
        self.isEnabled = isEnabled
        self.prefix = prefix
        self.privacy = privacy
        self.writesToStandardError = writesToStandardError
        self.logger = AutoCompLogger(category: category)
        self.unredactedSink = unredactedSink
    }

    func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let resolvedMessage = message()
        let safeMessage: String
        switch privacy {
        case .redactWholeMessage:
            safeMessage = AutoCompLogger.redactedSummary(for: resolvedMessage).description
        case .preRedactedStructured:
            safeMessage = resolvedMessage
        }
        let line = prefix.isEmpty ? safeMessage : "\(prefix) \(safeMessage)"
        logger.info(line)
        if writesToStandardError, let data = "\(line)\n".data(using: .utf8) {
            FileHandle.standardError.write(data)
        }
        unredactedSink?(resolvedMessage)
    }

    static func flagEnabled(
        argument: String,
        environmentVariable: String,
        arguments: [String] = ProcessInfo.processInfo.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        arguments.contains(argument) || environment[environmentVariable] == "1"
    }
}

enum SuggestionPipelineLog {
    private static let channel = DebugChannel(
        category: "suggestion-pipeline",
        prefix: "",
        isEnabled: DebugChannel.flagEnabled(
            argument: "--pipeline-debug",
            environmentVariable: "AUTOCOMP_PIPELINE_DEBUG"
        ),
        privacy: .preRedactedStructured
    )

    static let isEnabled = channel.isEnabled

    static func log(_ event: String, fields: @autoclosure () -> [String] = []) {
        channel.log(line(event: event, fields: fields()))
    }

    static func line(event: String, fields: [String] = []) -> String {
        (["pipeline", "event=\(event)"] + fields.filter { !$0.isEmpty })
            .joined(separator: " ")
    }

    static func contextDescription(_ context: TextContext?) -> String {
        guard let context else {
            return "nil"
        }

        let capture = ContextCaptureDiagnostics(context: context)
        return [
            "appBundle=\(context.app.bundleID)",
            "domain=\(context.domain ?? "nil")",
            "source=\(capture.contextSourceLogValue)",
            "trust=\(capture.trustTitle)",
            "geometry=\(capture.geometryQualityLogValue)",
            "prefixLen=\((context.textBeforeCursor as NSString).length)",
            "suffixLen=\(context.textAfterCursor.map { ($0 as NSString).length } ?? 0)",
            "selectedRange=\(selectedRangeDescription(context.selectedRange))",
            "selectedTextLen=\(context.selectedText.map { ($0 as NSString).length } ?? 0)",
            "trailingWhitespace=\(trailingWhitespaceDescription(context.textBeforeCursor))",
            "focusID=\(stableToken(for: context.focusedElementID))",
            "stableSeq=\(context.stableFieldIdentity?.focusChangeSequence.map(String.init) ?? "nil")"
        ].joined(separator: ",")
    }

    static func suggestionDescription(_ suggestion: Suggestion?) -> String {
        guard let suggestion else {
            return "nil"
        }

        return [
            "visibleLen=\((suggestion.visibleText as NSString).length)",
            "remainingLen=\((suggestion.remainingText as NSString).length)",
            "acceptedPrefixLen=\((suggestion.acceptedPrefix as NSString).length)",
            "alternatives=\(suggestion.alternatives.count)",
            "selected=\(suggestion.selectedAlternativeIndex)",
            "exhausted=\(suggestion.isExhausted)",
            "route=\(routeDescription(suggestion.completionRoute))",
            "bound=\(suggestion.binding == nil ? "false" : "true")"
        ].joined(separator: ",")
    }

    static func privacySafeErrorSummary(_ error: Error) -> String {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        return privacySafeTextSummary(message)
    }

    static func privacySafeTextSummary(_ text: String) -> String {
        let summary = AutoCompLogger.redactedSummary(for: text)
        return "chars:\(summary.characterCount),bytes:\(summary.utf8ByteCount),sha256:\(summary.sha256Prefix)"
    }

    static func routingDescription(_ policy: CompletionRoutingPolicy?) -> String {
        guard let policy else {
            return "unknown"
        }
        return "\(policy.activeKind.rawValue)->\(policy.fallbackKind?.rawValue ?? "none")"
    }

    static func discardReasonDescription(_ reason: SuggestionPipeline.DiscardReason) -> String {
        var fields = ["kind=\(reason.kind.rawValue)"]
        if let backendIssue = reason.backendIssue {
            fields.append("issue=\(backendIssue.logValue)")
        }
        if let message = reason.message {
            fields.append("message=\(privacySafeTextSummary(message))")
        }
        return fields.joined(separator: ",")
    }

    private static func routeDescription(_ route: CompletionRoute?) -> String {
        guard let route else {
            return "unknown"
        }
        return "\(route.requestedKind.rawValue)->\(route.deliveredKind.rawValue)"
    }

    private static func selectedRangeDescription(_ range: NSRange?) -> String {
        guard let range else {
            return "nil"
        }
        return "\(range.location):\(range.length)"
    }

    private static func trailingWhitespaceDescription(_ text: String) -> String {
        guard let lastScalar = text.unicodeScalars.last else {
            return "empty"
        }
        return CharacterSet.whitespacesAndNewlines.contains(lastScalar) ? "true" : "false"
    }

    private static func stableToken(for value: String) -> String {
        AutoCompLogger.redactedSummary(for: value).sha256Prefix
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
        completionTraceStore: CompletionTraceStore? = nil,
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

        try completionTraceStore?.export(to: exportDirectory)

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
        AutoCompUserDirectories.appSupportDirectory
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
