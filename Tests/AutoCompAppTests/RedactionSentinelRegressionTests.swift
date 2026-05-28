import AutoCompCore
@testable import AutoCompApp
import Foundation
import XCTest

final class RedactionSentinelRegressionTests: XCTestCase {
    private let axSentinel = "SECRET_AX_TEXT_123"
    private let clipboardSentinel = "SECRET_CLIPBOARD_123"
    private let ocrSentinel = "SECRET_OCR_123"
    private let promptSentinel = "SECRET_PROMPT_123"

    func testSensitiveDebugDisabledRedactsSentinelsAcrossNormalSurfaces() throws {
        let artifactDirectory = temporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: artifactDirectory)
        }
        let artifactStore = DebugArtifactStore(directory: artifactDirectory)
        let debugLogger = SuggestionDebugLogger(artifactStore: artifactStore)
        let context = sentinelContext()
        let visualContext = VisualContextSnapshot(summary: ocrSentinel)
        let clipboardContext = ClipboardContextSnapshot(
            summary: clipboardSentinel,
            status: .included,
            captureSources: [.clipboard]
        )
        let playgroundPreview = CompletionPlaygroundService().preview(
            prefix: axSentinel,
            suffix: promptSentinel,
            settings: CompletionBackendSettings(remoteModel: "test-model")
        )

        debugLogger.recordPlaygroundPreview(playgroundPreview, options: .normal)
        debugLogger.recordAutocomplete(
            context: context,
            privacySettings: PrivacySettings(
                collectionEnabled: true,
                clipboardContextEnabled: true,
                screenContextEnabled: true
            ),
            visualContext: visualContext,
            clipboardContext: clipboardContext,
            invocation: "manual",
            outcome: "published",
            suggestions: [sentinelSuggestion(baseContextID: context.id)],
            publishedSuggestion: sentinelSuggestion(baseContextID: context.id),
            rejectionReason: nil,
            discardReason: nil,
            errorDescription: nil,
            routingPolicy: CompletionRoutingPolicy(activeKind: .remote, fallbackKind: nil),
            options: .normal
        )

        var diagnostics = SuggestionDiagnostics()
        diagnostics.recordFocus(context: context)
        diagnostics.recordBackendSuccess(
            rawText: "Completion:\n\(promptSentinel)",
            normalizedText: "\(axSentinel) normalized",
            collectionAllowed: true,
            route: nil
        )
        diagnostics.recordEligibility(SuggestionEligibilityDecision(outcome: .eligible, statusMessage: nil, logs: []))

        let menuStatus = MenuStatusSnapshot.make(
            accessibilityTrusted: true,
            inputMonitoringAllowed: true,
            backendStatusSummary: .connected,
            inputMethod: diagnostics.inputMethod,
            focus: diagnostics.focus,
            focusFailure: diagnostics.focusFailure,
            lastDecision: diagnostics.lastDecision,
            compatibilityDecision: nil,
            autocompleteEnabled: true,
            now: Date(timeIntervalSince1970: 1)
        )

        let telemetryPayload = try redactedTelemetryPayload()
        let telemetryQueueAfterDelete = try redactedTelemetryQueueAfterDelete()
        let qaLog = try redactedQALogBody()
        let promptPreview = playgroundPreview.promptPreview(options: .normal) ?? "prompt preview hidden"

        assertNoSentinels(in: [
            "normal log summaries": redactedLogSummaries(),
            "debug-disabled artifacts": "artifactCount=\(artifactStore.artifactCount())",
            "telemetry payload": telemetryPayload,
            "telemetry queued artifacts": telemetryQueueAfterDelete,
            "menu diagnostics": diagnostics.menuRows
                .map { "\($0.title)=\($0.value)" }
                .joined(separator: "\n"),
            "status menu": menuStatus.items
                .map { "\($0.title)=\($0.value) action=\($0.action)" }
                .joined(separator: "\n"),
            "diagnostics output summaries": [
                diagnostics.output.rawPreview,
                diagnostics.output.normalizedPreview
            ].compactMap { $0 }.joined(separator: "\n"),
            "QA report/log": qaLog,
            "prompt preview": promptPreview
        ])
    }

    func testSensitiveDebugEnabledStoresSentinelsOnlyInLocalDeletableArtifacts() throws {
        let artifactDirectory = temporaryDirectory()
        let artifactStore = DebugArtifactStore(directory: artifactDirectory)
        let debugLogger = SuggestionDebugLogger(artifactStore: artifactStore)
        let options = AutoCompDebugOptions(localDebugOptIn: true)
        let context = sentinelContext()
        let playgroundPreview = CompletionPlaygroundService().preview(
            prefix: axSentinel,
            suffix: promptSentinel,
            settings: CompletionBackendSettings(remoteModel: "test-model")
        )
        defer {
            try? FileManager.default.removeItem(at: artifactDirectory)
        }

        debugLogger.recordPlaygroundPreview(playgroundPreview, options: options)
        debugLogger.recordAutocomplete(
            context: context,
            privacySettings: PrivacySettings(
                collectionEnabled: true,
                clipboardContextEnabled: true,
                screenContextEnabled: true
            ),
            visualContext: VisualContextSnapshot(summary: ocrSentinel),
            clipboardContext: ClipboardContextSnapshot(
                summary: clipboardSentinel,
                status: .included,
                captureSources: [.clipboard]
            ),
            invocation: "manual",
            outcome: "published",
            suggestions: [sentinelSuggestion(baseContextID: context.id)],
            publishedSuggestion: sentinelSuggestion(baseContextID: context.id),
            rejectionReason: nil,
            discardReason: nil,
            errorDescription: nil,
            routingPolicy: CompletionRoutingPolicy(activeKind: .remote, fallbackKind: nil),
            options: options
        )

        let artifactURLs = try FileManager.default.contentsOfDirectory(
            at: artifactDirectory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(artifactURLs.count, 2)
        let resolvedArtifactDirectory = artifactDirectory.resolvingSymlinksInPath().path
        for url in artifactURLs {
            XCTAssertTrue(
                url.resolvingSymlinksInPath().path.hasPrefix(resolvedArtifactDirectory),
                "Sensitive debug artifact escaped local debug directory: \(url.path)"
            )
        }

        let artifactBody = try artifactURLs
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")
        XCTAssertTrue(artifactBody.contains("AutoComp local debug artifact."))
        XCTAssertTrue(artifactBody.contains("Delete it from Settings > Privacy"))
        for sentinel in sentinels {
            XCTAssertTrue(
                artifactBody.contains(sentinel),
                "Expected local debug artifact to retain explicit debug sentinel: \(sentinel)"
            )
        }

        try artifactStore.deleteAll()

        XCTAssertEqual(artifactStore.artifactCount(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: artifactDirectory.path))
    }

    private var sentinels: [String] {
        [
            axSentinel,
            clipboardSentinel,
            ocrSentinel,
            promptSentinel
        ]
    }

    private func sentinelContext() -> TextContext {
        TextContext(
            app: AppIdentity(
                bundleID: "com.example.Writer",
                displayName: "Writer",
                processID: 42
            ),
            domain: "example.test",
            focusedElementID: "field",
            textBeforeCursor: axSentinel,
            textAfterCursor: promptSentinel,
            fullTextWindow: "\(axSentinel)\n\(promptSentinel)",
            captureSources: [.accessibility, .screenOCR, .clipboard]
        )
    }

    private func sentinelSuggestion(baseContextID: UUID) -> Suggestion {
        Suggestion(
            baseContextID: baseContextID,
            visibleText: "\(axSentinel) suggestion",
            rawText: "Completion:\n\(promptSentinel)",
            latencyMs: 12
        )
    }

    private func redactedLogSummaries() -> String {
        sentinels
            .map { AutoCompLogger.redactedSummary(for: $0).description }
            .joined(separator: "\n")
    }

    private func redactedTelemetryPayload() throws -> String {
        let sink = RecordingTelemetrySink()
        let client = RedactingTelemetryClient(enabled: true, sink: sink)

        client.capture(telemetryInput())

        return String(data: try JSONEncoder().encode(sink.events()), encoding: .utf8) ?? ""
    }

    private func redactedTelemetryQueueAfterDelete() throws -> String {
        let sink = RecordingTelemetrySink()
        let client = RedactingTelemetryClient(enabled: true, sink: sink)

        client.capture(telemetryInput())
        client.deleteAll()

        return String(data: try JSONEncoder().encode(sink.events()), encoding: .utf8) ?? ""
    }

    private func telemetryInput() -> TelemetryEventInput {
        TelemetryEventInput(
            name: "sentinel-redaction-regression",
            appVersion: "1.0.0",
            buildNumber: "1",
            backendKind: .remote,
            technicalError: TelemetryTechnicalError(category: "remote-backend", code: "timeout"),
            permissionStatuses: [
                .accessibility: .granted,
                .inputMonitoring: .granted,
                .screenRecording: .denied
            ],
            bundleID: "com.example.\(axSentinel)",
            prompt: promptSentinel,
            textBeforeCursor: axSentinel,
            textAfterCursor: promptSentinel,
            clipboard: clipboardSentinel,
            ocrText: ocrSentinel,
            screenshotDescription: ocrSentinel,
            suggestion: axSentinel,
            url: "https://example.test/private?\(promptSentinel)",
            domain: "\(clipboardSentinel).example.test"
        )
    }

    private func redactedQALogBody() throws -> String {
        let root = try packageRoot()
        let logURL = temporaryDirectory()
            .appendingPathExtension("log")
        defer {
            try? FileManager.default.removeItem(at: logURL)
        }

        try """
        Text before cursor:
        \(axSentinel)
        Prompt:
        \(promptSentinel)
        Clipboard context:
        \(clipboardSentinel)
        <visual_context>
        \(ocrSentinel)
        </visual_context>
        Raw output:
        \(promptSentinel)
        Normalized output:
        \(axSentinel)
        safe diagnostic reason
        """.write(to: logURL, atomically: true, encoding: .utf8)

        let process = Process()
        process.currentDirectoryURL = root
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "script/qa_real_app_matrix.sh",
            "--redact-log",
            logURL.path
        ]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let commandOutput = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, commandOutput)
        return try String(contentsOf: logURL, encoding: .utf8)
    }

    private func assertNoSentinels(
        in surfaces: [String: String],
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        for (surface, body) in surfaces.sorted(by: { $0.key < $1.key }) {
            for sentinel in sentinels {
                XCTAssertFalse(
                    body.contains(sentinel),
                    "Redaction leak in \(surface): \(sentinel)",
                    file: file,
                    line: line
                )
            }
        }
    }

    private func packageRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url.deleteLastPathComponent()
        }

        throw XCTSkip("Unable to locate package root")
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("autocomp-redaction-\(UUID().uuidString)", isDirectory: true)
    }
}

private final class RecordingTelemetrySink: TelemetryEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [TelemetryEvent] = []

    func send(_ event: TelemetryEvent) {
        lock.lock()
        storedEvents.append(event)
        lock.unlock()
    }

    func deleteAll() {
        lock.lock()
        storedEvents.removeAll()
        lock.unlock()
    }

    func events() -> [TelemetryEvent] {
        lock.lock()
        defer {
            lock.unlock()
        }
        return storedEvents
    }
}
