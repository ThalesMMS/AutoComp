import AutoCompCore
@testable import AutoCompApp
import XCTest

final class VisualContextCoordinatorTests: XCTestCase {
    func testVisualContextSummarizerNormalizesDeduplicatesAndLimitsLines() {
        let summarizer = VisualContextSummarizer(maxCharacters: 80, maxLines: 2)

        let summary = summarizer.summarize([
            VisualTextObservation(text: "  Budget   review  "),
            VisualTextObservation(text: "Budget review"),
            VisualTextObservation(text: "Q3\tforecast"),
            VisualTextObservation(text: "Do not include")
        ])

        XCTAssertEqual(summary?.text, "Budget review\nQ3 forecast")
        XCTAssertEqual(summary?.captureSources, [.screenOCR])
    }

    func testDisabledByPrivacyDoesNotCaptureVisualText() async throws {
        let privacyStore = try makePrivacyStore(PrivacySettings(screenContextEnabled: false))
        let capturer = RecordingVisualTextCapturer(observations: [
            VisualTextObservation(text: "Visible document")
        ])
        let coordinator = VisualContextCoordinator(
            privacyStore: privacyStore,
            visualTextCapturer: capturer,
            screenCaptureAllowed: { true }
        )

        let snapshot = await coordinator.currentVisualContext()

        XCTAssertNil(snapshot)
        let callCount = await capturer.callCount()
        XCTAssertEqual(callCount, 0)
    }

    func testDeniedScreenCapturePermissionDoesNotCaptureVisualText() async throws {
        let privacyStore = try makePrivacyStore(PrivacySettings(screenContextEnabled: true))
        let identity = stableFieldIdentity(id: "field-a")
        let capturer = RecordingVisualTextCapturer(observations: [
            VisualTextObservation(text: "Visible document")
        ])
        let coordinator = VisualContextCoordinator(
            privacyStore: privacyStore,
            visualTextCapturer: capturer,
            screenCaptureAllowed: { false }
        )

        let snapshot = await coordinator.currentVisualContext(for: identity)

        XCTAssertNil(snapshot)
        XCTAssertEqual(coordinator.currentSession()?.state, .failed)
        XCTAssertEqual(coordinator.currentSession()?.statusMessage, "Screen Recording permission is off")
        let callCount = await capturer.callCount()
        XCTAssertEqual(callCount, 0)
    }

    func testEmptyVisualSummaryReturnsNil() async throws {
        let privacyStore = try makePrivacyStore(PrivacySettings(screenContextEnabled: true))
        let capturer = RecordingVisualTextCapturer(observations: [
            VisualTextObservation(text: "  \n\t ")
        ])
        let coordinator = VisualContextCoordinator(
            privacyStore: privacyStore,
            visualTextCapturer: capturer,
            screenCaptureAllowed: { true }
        )

        let snapshot = await coordinator.currentVisualContext()

        XCTAssertNil(snapshot)
        let callCount = await capturer.callCount()
        XCTAssertEqual(callCount, 1)
    }

    func testValidVisualSummaryIsNormalizedLimitedAndCarriesSources() async throws {
        let privacyStore = try makePrivacyStore(PrivacySettings(screenContextEnabled: true))
        let identity = stableFieldIdentity(id: "field-a")
        let capturer = RecordingVisualTextCapturer(observations: [
            VisualTextObservation(text: "  Budget   review  "),
            VisualTextObservation(text: "Budget review"),
            VisualTextObservation(text: "Q3\tforecast", captureSource: .screenOCR),
            VisualTextObservation(text: "Do not include this line", captureSource: .screenOCR),
            VisualTextObservation(text: String(repeating: "x", count: 160), captureSource: .screenOCR)
        ])
        let coordinator = VisualContextCoordinator(
            privacyStore: privacyStore,
            visualTextCapturer: capturer,
            screenCaptureAllowed: { true },
            maxSummaryCharacters: 90,
            maxSummaryLines: 2
        )

        let resolvedSnapshot = await coordinator.currentVisualContext(for: identity)
        let snapshot = try XCTUnwrap(resolvedSnapshot)

        XCTAssertLessThanOrEqual(snapshot.summary.count, 90)
        XCTAssertEqual(snapshot.summary, "Budget review\nQ3 forecast")
        XCTAssertEqual(snapshot.captureSources, [.screenOCR])
        XCTAssertEqual(snapshot.stableFieldIdentity, identity)
        XCTAssertEqual(coordinator.currentSession()?.state, .ready)
        XCTAssertEqual(coordinator.currentSession()?.identity, identity)
    }

    func testReadyVisualContextIsReusedOnlyForSameFieldUntilExpired() async throws {
        let privacyStore = try makePrivacyStore(PrivacySettings(screenContextEnabled: true))
        let clock = VisualContextTestClock()
        let identity = stableFieldIdentity(id: "field-a")
        let otherIdentity = stableFieldIdentity(id: "field-b")
        let capturer = RecordingVisualTextCapturer(observations: [
            VisualTextObservation(text: "Visible document")
        ])
        let coordinator = VisualContextCoordinator(
            privacyStore: privacyStore,
            visualTextCapturer: capturer,
            screenCaptureAllowed: { true },
            sessionTTL: 1,
            now: { clock.now }
        )

        let first = await coordinator.currentVisualContext(for: identity)
        let second = await coordinator.currentVisualContext(for: identity)
        let other = await coordinator.currentVisualContext(for: otherIdentity)
        clock.advance(by: 2)
        let expired = await coordinator.currentVisualContext(for: otherIdentity)

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first?.stableFieldIdentity, other?.stableFieldIdentity)
        XCTAssertNotNil(expired)
        let callCount = await capturer.callCount()
        XCTAssertEqual(callCount, 3)
    }

    func testInFlightVisualContextIsDiscardedWhenFieldChanges() async throws {
        let privacyStore = try makePrivacyStore(PrivacySettings(screenContextEnabled: true))
        let firstIdentity = stableFieldIdentity(id: "field-a")
        let secondIdentity = stableFieldIdentity(id: "field-b")
        let capturer = SuspendedVisualTextCapturer()
        let coordinator = VisualContextCoordinator(
            privacyStore: privacyStore,
            visualTextCapturer: capturer,
            screenCaptureAllowed: { true }
        )

        let firstTask = Task {
            await coordinator.currentVisualContext(for: firstIdentity)
        }
        await capturer.waitForPendingCaptureCount(1)

        let secondTask = Task {
            await coordinator.currentVisualContext(for: secondIdentity)
        }
        await capturer.waitForPendingCaptureCount(2)

        await capturer.resumeNext(with: [VisualTextObservation(text: "First field")])
        await capturer.resumeNext(with: [VisualTextObservation(text: "Second field")])

        let firstSnapshot = await firstTask.value
        let secondSnapshot = await secondTask.value

        XCTAssertNil(firstSnapshot)
        XCTAssertEqual(secondSnapshot?.summary, "Second field")
        XCTAssertEqual(secondSnapshot?.stableFieldIdentity, secondIdentity)
    }

    private func makePrivacyStore(_ settings: PrivacySettings) throws -> PrivacySettingsStore {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AutoCompVisualContext-\(UUID().uuidString)"))
        let store = PrivacySettingsStore(defaults: defaults, key: "privacy")
        try store.save(settings)
        return store
    }

    private func stableFieldIdentity(id: String) -> StableFieldIdentity {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        return StableFieldIdentity(
            app: app,
            role: "AXTextArea",
            focusedElementFrame: id == "field-a"
                ? CGRect(x: 100, y: 100, width: 400, height: 40)
                : CGRect(x: 100, y: 180, width: 400, height: 40),
            focusChangeSequence: id == "field-a" ? 1 : 2
        )
    }
}

private actor RecordingVisualTextCapturer: VisualTextCapturing {
    private let observations: [VisualTextObservation]
    private var storedCallCount = 0

    init(observations: [VisualTextObservation]) {
        self.observations = observations
    }

    func callCount() -> Int {
        storedCallCount
    }

    func captureVisibleText() async -> [VisualTextObservation] {
        storedCallCount += 1
        return observations
    }
}

private actor SuspendedVisualTextCapturer: VisualTextCapturing {
    private var continuations: [CheckedContinuation<[VisualTextObservation], Never>] = []

    func captureVisibleText() async -> [VisualTextObservation] {
        await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitForPendingCaptureCount(_ count: Int) async {
        while continuations.count < count {
            await Task.yield()
        }
    }

    func resumeNext(with observations: [VisualTextObservation]) {
        guard !continuations.isEmpty else {
            return
        }
        continuations.removeFirst().resume(returning: observations)
    }
}

private final class VisualContextTestClock {
    private(set) var now = Date(timeIntervalSince1970: 5_000)

    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }
}
