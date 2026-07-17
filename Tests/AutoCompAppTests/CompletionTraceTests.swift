import AutoCompCore
@testable import AutoCompApp
import Foundation
import XCTest

final class CompletionTraceSchemaTests: XCTestCase {
    func testSchemaHasCanonicalTaxonomyAndCannotEncodeContentFields() throws {
        let context = CompletionTraceContext(
            parentTraceID: CompletionTraceID(),
            originTraceID: CompletionTraceID(),
            presentationAttempt: 2
        )
        let event = CompletionTraceEvent(
            context: context,
            event: .providerCompleted,
            outcome: .ready,
            workID: 7,
            providerAttempt: 1,
            durationMs: 42,
            requestedBackend: .localLlama,
            deliveredBackend: .remote,
            prefixUTF16Length: 15,
            suffixUTF16Length: 4,
            candidateCount: 3,
            candidateRank: 1,
            hostPublishOutcome: .published,
            hostPublishMs: 10,
            hostPublishPollCount: 2,
            targetDebounceMs: 40,
            remainingDebounceMs: 30,
            schedulingReason: .hostPublishConsumedWindow,
            recentBackendLatencyMs: 20,
            providerCallStarted: true,
            reuseSnapshotAgeBucket: 1,
            remainingCharacterBucket: 2,
            inlineCommandKind: .macro,
            inlineCommandQueryUTF16Length: 5,
            providerSequence: 3,
            partialCount: 2,
            timeToFirstSafePartialMs: 12,
            timeToFinalMs: 40,
            earlyAcceptance: true
        )

        let body = try XCTUnwrap(String(
            bytes: JSONEncoder().encode(event),
            encoding: .utf8
        ))
        for forbiddenKey in [
            "prompt",
            "textBeforeCursor",
            "textAfterCursor",
            "selectedText",
            "rawOutput",
            "normalizedOutput",
            "ocr",
            "clipboard",
            "apiKey",
            "headers"
        ] {
            XCTAssertFalse(body.contains(forbiddenKey), "Trace schema exposed forbidden field: \(forbiddenKey)")
        }

        XCTAssertEqual(event.schemaVersion, 6)
        XCTAssertEqual(event.parentTraceID, context.parentTraceID)
        XCTAssertEqual(event.originTraceID, context.originTraceID)
        XCTAssertEqual(event.providerAttempt, 1)
        XCTAssertEqual(event.remainingDebounceMs, 30)
        XCTAssertEqual(event.hostPublishPollCount, 2)
        XCTAssertEqual(event.reuseSnapshotAgeBucket, 1)
        XCTAssertEqual(event.remainingCharacterBucket, 2)
        XCTAssertEqual(event.inlineCommandKind, .macro)
        XCTAssertEqual(event.inlineCommandQueryUTF16Length, 5)
        XCTAssertEqual(event.providerSequence, 3)
        XCTAssertEqual(event.partialCount, 2)
        XCTAssertEqual(event.timeToFirstSafePartialMs, 12)
        XCTAssertEqual(event.timeToFinalMs, 40)
        XCTAssertEqual(event.earlyAcceptance, true)
        XCTAssertTrue(CompletionTraceEventName.allCases.contains(.reusePromoted))
        XCTAssertTrue(CompletionTraceEventName.allCases.contains(.reuseRollbackRestored))
        XCTAssertTrue(CompletionTraceEventName.allCases.contains(.reuseMiss))
        XCTAssertTrue(CompletionTraceEventName.allCases.contains(.speculationStarted))
        XCTAssertTrue(CompletionTraceEventName.allCases.contains(.speculationValidated))
        XCTAssertTrue(CompletionTraceEventName.allCases.contains(.speculationDiverged))
        XCTAssertTrue(CompletionTraceEventName.allCases.contains(.inlineCommandOpened))
        XCTAssertTrue(CompletionTraceEventName.allCases.contains(.inlineCommandCommitted))
        XCTAssertTrue(CompletionTraceEventName.allCases.contains(.streamPartialReceived))
        XCTAssertTrue(CompletionTraceEventName.allCases.contains(.streamEarlyAccepted))
        XCTAssertTrue(CompletionTraceEventName.allCases.contains(.traceFinished))
    }
}

final class CompletionTraceStoreTests: XCTestCase {
    func testStoreRequiresOptInRotatesExportsAndDeletes() throws {
        let root = temporaryDirectory()
        let exportRoot = temporaryDirectory()
        let store = CompletionTraceStore(
            directory: root,
            maximumFileBytes: 700,
            isEnabled: false
        )
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: exportRoot)
        }

        store.record(makeEvent(index: 0))
        store.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))

        store.setEnabled(true)
        for index in 0..<12 {
            store.record(makeEvent(index: index))
        }
        store.flush()

        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        XCTAssertEqual(Set(files.map(\.lastPathComponent)), [
            "completion-traces.1.jsonl",
            "completion-traces.jsonl"
        ])
        XCTAssertFalse(try store.events().isEmpty)

        let artifactStore = DebugArtifactStore(
            directory: root.appendingPathExtension("artifacts")
        )
        let exportDate = Date(timeIntervalSince1970: 42)
        let exportURL = try artifactStore.exportDebugLogs(
            to: exportRoot,
            options: .normal,
            completionTraceStore: store,
            createdAt: exportDate
        )
        XCTAssertEqual(
            try artifactStore.exportDebugLogs(
                to: exportRoot,
                options: .normal,
                completionTraceStore: store,
                createdAt: exportDate
            ),
            exportURL
        )
        let exported = try FileManager.default.contentsOfDirectory(
            at: exportURL.appendingPathComponent("CompletionTraces", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(exported.count, 2)

        try store.deleteAll()
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testDiskFailureIsCountedAndNeverEscapesRecordCall() throws {
        let fileURL = temporaryDirectory()
        try "not a directory".write(to: fileURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let store = CompletionTraceStore(directory: fileURL, isEnabled: true)

        store.record(makeEvent(index: 1))
        store.flush()

        XCTAssertEqual(store.writeFailureCount(), 1)
    }

    private func makeEvent(index: Int) -> CompletionTraceEvent {
        CompletionTraceEvent(
            context: CompletionTraceContext(),
            event: .providerCompleted,
            outcome: .ready,
            timestamp: Date(timeIntervalSince1970: TimeInterval(index)),
            workID: index,
            providerAttempt: 0,
            durationMs: index,
            candidateCount: 1,
            candidateRank: 0
        )
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("autocomp-trace-\(UUID().uuidString)", isDirectory: true)
    }
}

@MainActor
final class CompletionTraceEngineTests: XCTestCase {
    func testAutomaticSuggestionCarriesTraceThroughHostPublishAndDebounce() async throws {
        let context = TextContextFixtures.textEdit(prefix: "Automatic ")
        let recorder = RecordingCompletionTraceRecorder()
        let engine = SuggestionEngine(
            contextProvider: FakeContextProvider(context: context),
            completionProvider: FakeCompletionProvider(text: "completion"),
            presenter: FakeSuggestionPresenter(),
            completionTraceRecorder: recorder
        )

        engine.recordCapturedInputEvent(InputEventFixtures.spaceTrigger)
        try await waitUntil(timeout: .seconds(4)) { engine.currentSuggestion != nil }

        let events = recorder.events()
        XCTAssertEqual(Set(events.map(\.traceID)).count, 1)
        let names = events.map(\.event)
        for requiredEvent in [
            CompletionTraceEventName.inputObserved,
            .hostPublishStarted,
            .hostPublishReady,
            .contextCaptured,
            .eligibilityDecided,
            .schedulingDecided,
            .debounceStarted,
            .debounceElapsed,
            .requestBuilt,
            .providerStarted,
            .providerCompleted,
            .published
        ] {
            XCTAssertTrue(names.contains(requiredEvent), "Missing automatic trace event: \(requiredEvent.rawValue)")
        }
        let scheduling = try XCTUnwrap(events.first { $0.event == .schedulingDecided })
        XCTAssertEqual(scheduling.hostPublishOutcome, .published)
        XCTAssertGreaterThanOrEqual(scheduling.hostPublishMs ?? -1, 0)
        XCTAssertGreaterThanOrEqual(scheduling.hostPublishPollCount ?? -1, 1)
        XCTAssertEqual(
            scheduling.remainingDebounceMs,
            max(0, (scheduling.targetDebounceMs ?? 0) - (scheduling.hostPublishMs ?? 0))
        )
        XCTAssertEqual(scheduling.requestedBackend, .remote)
    }

    func testHostTimeoutIsExplicitAndConsumesAdaptiveWindow() async throws {
        let context = TextContextFixtures.textEdit(prefix: "Timeout ")
        let recorder = RecordingCompletionTraceRecorder()
        let engine = SuggestionEngine(
            contextProvider: FakeContextProvider(context: context),
            completionProvider: FakeCompletionProvider(text: "completion"),
            presenter: FakeSuggestionPresenter(),
            hostPublishAwaiter: HostPublishAwaiter(configuration: .fastTest),
            completionTraceRecorder: recorder
        )
        engine.recordCapturedInputEvent(InputEventFixtures.spaceTrigger)
        try await waitUntil(timeout: .seconds(2)) { engine.currentSuggestion != nil }
        engine.recordCapturedInputEvent(.text(
            keyCode: CapturedInputEventAdapter.deleteKeyCode,
            isSuggestionTrigger: false
        ))
        XCTAssertNil(engine.currentSuggestion)
        engine.recordCapturedInputEvent(InputEventFixtures.spaceTrigger)
        try await waitUntil(timeout: .seconds(2)) {
            recorder.events().contains {
                $0.event == .schedulingDecided && $0.hostPublishOutcome == .timeout
            }
        }

        let recordedEvents = recorder.events()
        let eventDescriptions = recordedEvents.map { event in
            "\(event.event.rawValue):\(event.hostPublishOutcome?.rawValue ?? "nil")"
        }
        let scheduling = try XCTUnwrap(recordedEvents.last {
            $0.event == .schedulingDecided && $0.hostPublishOutcome == .timeout
        }, "Events: \(eventDescriptions)")
        XCTAssertEqual(scheduling.schedulingReason, .hostPublishTimeout)
        XCTAssertEqual(
            scheduling.remainingDebounceMs,
            max(0, (scheduling.targetDebounceMs ?? 0) - (scheduling.hostPublishMs ?? 0))
        )
        XCTAssertTrue(recorder.events().contains { $0.event == .providerStarted && $0.providerCallStarted == true })
        engine.stop()
    }

    func testPublishedAndAcceptedSuggestionHasOneCompleteTimeline() async throws {
        let context = TextContextFixtures.textEdit(prefix: "Trace this ")
        let recorder = RecordingCompletionTraceRecorder()
        let presenter = FakeSuggestionPresenter()
        let engine = SuggestionEngine(
            contextProvider: FakeContextProvider(context: context),
            completionProvider: FakeCompletionProvider(text: "completion"),
            presenter: presenter,
            completionTraceRecorder: recorder
        )

        await engine.triggerManualSuggestion()
        try await waitUntil { engine.currentSuggestion != nil }
        let outcome = await engine.acceptAll(using: FakeTextInserter())
        XCTAssertEqual(outcome, .accepted)

        let events = recorder.events()
        let traceIDs = Set(events.map(\.traceID))
        XCTAssertEqual(traceIDs.count, 1)
        let names = events.map(\.event)
        for requiredEvent in [
            CompletionTraceEventName.inputObserved,
            .contextCaptured,
            .eligibilityDecided,
            .schedulingDecided,
            .requestBuilt,
            .providerStarted,
            .providerCompleted,
            .liveContextRevalidated,
            .privacyGateDecided,
            .normalized,
            .published,
            .overlayPresented,
            .acceptanceAttempted,
            .acceptanceAllowed,
            .acceptanceInserted,
            .sessionExhausted,
            .traceFinished
        ] {
            XCTAssertTrue(names.contains(requiredEvent), "Missing trace event: \(requiredEvent.rawValue)")
        }
        XCTAssertEqual(names.last, .traceFinished)
        let scheduling = try XCTUnwrap(events.first { $0.event == .schedulingDecided })
        XCTAssertEqual(scheduling.schedulingReason, .manualImmediate)
        XCTAssertEqual(scheduling.remainingDebounceMs, 0)
    }

    func testFallbackKeepsTraceAndUsesDistinctProviderAttempt() async throws {
        let context = TextContextFixtures.textEdit(prefix: "Fallback ")
        let suggestion = Suggestion(
            baseContextID: context.id,
            visibleText: "completed",
            completionRoute: CompletionRoute(
                requestedKind: .localLlama,
                deliveredKind: .remote,
                fallbackErrorDescription: "synthetic failure"
            ),
            latencyMs: 2
        )
        let recorder = RecordingCompletionTraceRecorder()
        let engine = SuggestionEngine(
            contextProvider: FakeContextProvider(context: context),
            completionProvider: FakeCompletionProvider(suggestions: [suggestion]),
            presenter: FakeSuggestionPresenter(),
            completionTraceRecorder: recorder
        )

        await engine.triggerManualSuggestion()
        try await waitUntil { engine.currentSuggestion != nil }

        let events = recorder.events()
        XCTAssertEqual(Set(events.map(\.traceID)).count, 1)
        XCTAssertTrue(events.contains { $0.event == .providerFailed && $0.providerAttempt == 0 })
        XCTAssertTrue(events.contains { $0.event == .fallbackStarted && $0.providerAttempt == 1 })
        XCTAssertTrue(events.contains {
            $0.event == .providerCompleted
                && $0.providerAttempt == 1
                && $0.requestedBackend == .localLlama
                && $0.deliveredBackend == .remote
        })
    }

    private func waitUntil(
        timeout: Duration = .seconds(3),
        condition: @escaping @MainActor () -> Bool
    ) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while !condition() {
            guard clock.now < deadline else {
                XCTFail("Timed out waiting for trace test condition")
                return
            }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class RecordingCompletionTraceRecorder: CompletionTraceRecording, @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [CompletionTraceEvent] = []

    func record(_ event: CompletionTraceEvent) {
        lock.withLock {
            storedEvents.append(event)
        }
    }

    func events() -> [CompletionTraceEvent] {
        lock.withLock { storedEvents }
    }
}
