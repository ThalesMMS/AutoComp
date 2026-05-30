import AutoCompCore
@testable import AutoCompApp
import Foundation
import XCTest

@MainActor
final class StartupPrivacyRegressionTests: XCTestCase {
    func testEngineStartupWithoutFocusDoesNotCallBackendClipboardOrVisualContext() async throws {
        let privacyStore = try makePrivacyStore(clipboardEnabled: true, screenEnabled: true)
        let completionProvider = FakeCompletionProvider(text: "private completion")
        let visualContextProvider = FakeVisualContextProvider(
            snapshot: VisualContextSnapshot(summary: "visible secret")
        )
        let clipboardProvider = RecordingClipboardContextProvider(
            snapshot: ClipboardContextSnapshot(
                summary: "clipboard secret",
                status: .included,
                captureSources: [.clipboard]
            )
        )
        let engine = SuggestionEngine(
            contextProvider: FakeContextProvider(contexts: [], error: AXTextContextError.noFocusedElement),
            completionProvider: completionProvider,
            visualContextProvider: visualContextProvider,
            clipboardContextProvider: clipboardProvider,
            presenter: FakeSuggestionPresenter(),
            privacyStore: privacyStore
        )
        defer {
            engine.stop()
        }

        engine.start()
        try await Task.sleep(nanoseconds: 650_000_000)

        let recordedContexts = await completionProvider.recordedContexts()
        XCTAssertTrue(recordedContexts.isEmpty)
        XCTAssertTrue(visualContextProvider.requestedIdentities().isEmpty)
        XCTAssertEqual(clipboardProvider.requestCount(), 0)
    }

    func testStartupWithFocusedFieldButNoAllowedTriggerDoesNotReadSensitiveContext() async throws {
        let privacyStore = try makePrivacyStore(clipboardEnabled: true, screenEnabled: true)
        let initialContext = TextContextFixtures.textEdit(prefix: "Already typed ")
        let completionProvider = FakeCompletionProvider(text: "completion")
        let visualContextProvider = FakeVisualContextProvider(
            snapshot: VisualContextSnapshot(summary: "visible secret")
        )
        let clipboardProvider = RecordingClipboardContextProvider(
            snapshot: ClipboardContextSnapshot(
                summary: "clipboard secret",
                status: .included,
                captureSources: [.clipboard]
            )
        )
        let engine = SuggestionEngine(
            contextProvider: FakeContextProvider(context: initialContext),
            completionProvider: completionProvider,
            visualContextProvider: visualContextProvider,
            clipboardContextProvider: clipboardProvider,
            presenter: FakeSuggestionPresenter(),
            privacyStore: privacyStore
        )
        defer {
            engine.stop()
        }

        engine.start()
        try await Task.sleep(nanoseconds: 700_000_000)

        let recordedContexts = await completionProvider.recordedContexts()
        XCTAssertTrue(recordedContexts.isEmpty)
        XCTAssertTrue(visualContextProvider.requestedIdentities().isEmpty)
        XCTAssertEqual(clipboardProvider.requestCount(), 0)
        XCTAssertEqual(engine.diagnostics.eligibility?.outcome, "ineligible")
    }

    func testAllowedCompletionReadsVisualAndClipboardOnlyForConcreteFieldRequest() async throws {
        let privacyStore = try makePrivacyStore(clipboardEnabled: true, screenEnabled: true)
        let context = TextContextFixtures.textEdit(prefix: "Please ")
        let visualSnapshot = VisualContextSnapshot(
            summary: "Visible title Budget Review",
            stableFieldIdentity: context.stableFieldIdentity
        )
        let clipboardSnapshot = ClipboardContextSnapshot(
            summary: "Budget Review owner",
            status: .included,
            captureSources: [.clipboard]
        )
        let completionProvider = FakeCompletionProvider(text: "finish this")
        let visualContextProvider = FakeVisualContextProvider(snapshot: visualSnapshot)
        let clipboardProvider = RecordingClipboardContextProvider(snapshot: clipboardSnapshot)
        let engine = SuggestionEngine(
            contextProvider: FakeContextProvider(context: context),
            completionProvider: completionProvider,
            visualContextProvider: visualContextProvider,
            clipboardContextProvider: clipboardProvider,
            presenter: FakeSuggestionPresenter(),
            privacyStore: privacyStore
        )
        defer {
            engine.stop()
        }

        engine.recordCapturedInputEvent(InputEventFixtures.spaceTrigger)
        try await Task.sleep(nanoseconds: 700_000_000)

        let recordedVisualContexts = await completionProvider.recordedVisualContexts()
        let recordedClipboardContexts = await completionProvider.recordedClipboardContexts()
        XCTAssertEqual(visualContextProvider.requestedIdentities(), [context.stableFieldIdentity])
        XCTAssertEqual(clipboardProvider.requestedContexts().map(\.id), [context.id])
        XCTAssertEqual(recordedVisualContexts, [visualSnapshot])
        XCTAssertEqual(recordedClipboardContexts, [clipboardSnapshot])
    }

    func testControllerStartupKeepsRemoteProbeAndTelemetryCaptureOutOfStart() throws {
        let source = try String(
            contentsOf: try packageRoot().appendingPathComponent("Sources/AutoCompApp/App/AppController.swift"),
            encoding: .utf8
        )
        let environmentSource = try String(
            contentsOf: try packageRoot().appendingPathComponent("Sources/AutoCompApp/App/AutoCompAppEnvironment.swift"),
            encoding: .utf8
        )
        let startBody = try functionBody(
            named: "start",
            in: source,
            endingBefore: "private func startKeyboardShortcuts"
        )

        XCTAssertFalse(startBody.contains("RemoteBackendProbe"))
        XCTAssertFalse(startBody.contains("testRemoteConnection"))
        XCTAssertFalse(startBody.contains("telemetryClient.capture"))
        XCTAssertEqual(source.occurrenceCount(of: "RemoteBackendProbe().testConnection"), 1)
        XCTAssertEqual(source.occurrenceCount(of: "telemetryClient.capture"), 1)
        XCTAssertTrue(source.contains("func testRemoteConnection(settings: CompletionBackendSettings) async -> RemoteBackendProbeResult"))
        XCTAssertTrue(source.contains("private func recordRemoteProbeTelemetry"))
        XCTAssertTrue(environmentSource.contains("let telemetryClient = DisabledTelemetryClient()"))
        XCTAssertFalse(environmentSource.contains("RedactingTelemetryClient"))
    }

    func testOpeningMenuDoesNotRestartController() throws {
        let menuSource = try String(
            contentsOf: try packageRoot().appendingPathComponent("Sources/AutoCompApp/Views/MenuBarContentView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(menuSource.contains("controller.start()"))
    }

    private func makePrivacyStore(
        clipboardEnabled: Bool,
        screenEnabled: Bool
    ) throws -> PrivacySettingsStore {
        let defaultsName = "StartupPrivacyRegressionTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        addTeardownBlock {
            defaults.removePersistentDomain(forName: defaultsName)
        }
        let store = PrivacySettingsStore(defaults: defaults, key: "privacy")
        try store.save(PrivacySettings(
            collectionEnabled: true,
            clipboardContextEnabled: clipboardEnabled,
            screenContextEnabled: screenEnabled,
            telemetryEnabled: true
        ))
        return store
    }

    private func functionBody(
        named functionName: String,
        in source: String,
        endingBefore nextFunction: String
    ) throws -> Substring {
        let startMarker = "func \(functionName)() {"
        let startRange = try XCTUnwrap(source.range(of: startMarker))
        let remaining = source[startRange.upperBound...]
        let endRange = try XCTUnwrap(remaining.range(of: nextFunction))
        return remaining[..<endRange.lowerBound]
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
}

private final class RecordingClipboardContextProvider: ClipboardContextProvider, @unchecked Sendable {
    private let snapshot: ClipboardContextSnapshot?
    private let lock = NSLock()
    private var contexts: [TextContext] = []

    init(snapshot: ClipboardContextSnapshot?) {
        self.snapshot = snapshot
    }

    func currentClipboardContext(
        for context: TextContext,
        privacySettings: PrivacySettings
    ) -> ClipboardContextSnapshot? {
        lock.lock()
        contexts.append(context)
        lock.unlock()
        return snapshot
    }

    func requestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return contexts.count
    }

    func requestedContexts() -> [TextContext] {
        lock.lock()
        defer { lock.unlock() }
        return contexts
    }
}

private extension String {
    func occurrenceCount(of needle: String) -> Int {
        components(separatedBy: needle).count - 1
    }
}
