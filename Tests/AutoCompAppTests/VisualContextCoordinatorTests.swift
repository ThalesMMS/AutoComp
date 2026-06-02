import AutoCompCore
import CoreGraphics
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

    func testVisualContextSummarizerStripsFieldTextAndCorruptLines() {
        let summarizer = VisualContextSummarizer(maxCharacters: 120, maxLines: 4, minimumConfidence: 0.5)

        let summary = summarizer.summarize(
            [
                VisualTextObservation(text: "Please finish this sentence", confidence: 0.99),
                VisualTextObservation(text: "Visible PDF heading", confidence: 0.99),
                VisualTextObservation(text: "%%%%%%% $$$$", confidence: 0.99),
                VisualTextObservation(text: "Low confidence side note", confidence: 0.2)
            ],
            excludingFieldText: ["Please finish this sentence"]
        )

        XCTAssertEqual(summary?.text, "Visible PDF heading")
    }

    func testDisabledByPrivacyDoesNotCaptureVisualText() async throws {
        let privacyStore = try makePrivacyStore(PrivacySettings(screenContextEnabled: false))
        let identity = stableFieldIdentity(id: "field-a")
        let capturer = RecordingVisualTextCapturer(observations: [
            VisualTextObservation(text: "Visible document")
        ])
        let coordinator = VisualContextCoordinator(
            privacyStore: privacyStore,
            visualTextCapturer: capturer,
            screenCaptureAllowed: { true }
        )

        coordinator.startIfEligible(for: textContext(identity: identity, textBeforeCursor: "Please "))
        let snapshot = await coordinator.currentVisualContext(for: identity)

        XCTAssertNil(snapshot)
        XCTAssertEqual(coordinator.currentSession()?.state, .failed)
        XCTAssertEqual(coordinator.currentSession()?.statusMessage, "Visual context disabled by privacy settings")
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

        coordinator.startIfEligible(for: textContext(identity: identity, textBeforeCursor: "Please "))
        let snapshot = await coordinator.currentVisualContext(for: identity)

        XCTAssertNil(snapshot)
        XCTAssertEqual(coordinator.currentSession()?.state, .failed)
        XCTAssertEqual(coordinator.currentSession()?.statusMessage, "Screen Recording permission is off")
        let callCount = await capturer.callCount()
        XCTAssertEqual(callCount, 0)
    }

    func testSuspendedPipelineDoesNotCaptureVisualContext() async throws {
        let privacyStore = try makePrivacyStore(PrivacySettings(screenContextEnabled: true))
        let suspensionController = InteractionPipelineSuspensionController()
        _ = suspensionController.suspend(reason: .openPanel)
        let identity = stableFieldIdentity(id: "field-a")
        let capturer = RecordingVisualTextCapturer(observations: [
            VisualTextObservation(text: "Visible document")
        ])
        let coordinator = VisualContextCoordinator(
            privacyStore: privacyStore,
            visualTextCapturer: capturer,
            interactionPipelineSuspensionController: suspensionController,
            screenCaptureAllowed: { true }
        )

        coordinator.startIfEligible(for: textContext(identity: identity, textBeforeCursor: "Please "))
        let snapshot = await coordinator.currentVisualContext(for: identity)

        XCTAssertNil(snapshot)
        XCTAssertEqual(coordinator.currentSession()?.state, .failed)
        XCTAssertEqual(coordinator.currentSession()?.statusMessage, "Visual context paused")
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

        coordinator.startIfEligible(for: textContext(identity: stableFieldIdentity(id: "field-a"), textBeforeCursor: "Please "))
        await capturer.waitForCallCount(1)
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

        coordinator.startIfEligible(for: textContext(identity: identity, textBeforeCursor: "Please "))
        await capturer.waitForCallCount(1)
        await waitForSessionState(.ready, coordinator: coordinator)
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

        coordinator.startIfEligible(for: textContext(identity: identity, textBeforeCursor: "Please "))
        await capturer.waitForCallCount(1)
        await waitForSessionState(.ready, coordinator: coordinator)
        let first = await coordinator.currentVisualContext(for: identity)
        let second = await coordinator.currentVisualContext(for: identity)
        coordinator.refreshOnFocusOrWindowChange(textContext(identity: otherIdentity, textBeforeCursor: "Please "))
        await capturer.waitForCallCount(2)
        await waitForSessionState(.ready, coordinator: coordinator)
        let other = await coordinator.currentVisualContext(for: otherIdentity)
        clock.advance(by: 2)
        let expired = await coordinator.currentVisualContext(for: otherIdentity)

        XCTAssertEqual(first, second)
        XCTAssertNotEqual(first?.stableFieldIdentity, other?.stableFieldIdentity)
        XCTAssertNil(expired)
        let callCount = await capturer.callCount()
        XCTAssertEqual(callCount, 2)
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

        coordinator.startIfEligible(for: textContext(identity: firstIdentity, textBeforeCursor: "Please "))
        await capturer.waitForPendingCaptureCount(1)

        coordinator.refreshOnFocusOrWindowChange(textContext(identity: secondIdentity, textBeforeCursor: "Please "))
        await capturer.waitForPendingCaptureCount(2)

        await capturer.resumeNext(with: [VisualTextObservation(text: "First field")])
        await capturer.resumeNext(with: [VisualTextObservation(text: "Second field")])
        await waitForSessionState(.ready, coordinator: coordinator)

        let firstSnapshot = await coordinator.currentVisualContext(for: firstIdentity)
        let secondSnapshot = await coordinator.currentVisualContext(for: secondIdentity)

        XCTAssertNil(firstSnapshot)
        XCTAssertEqual(secondSnapshot?.summary, "Second field")
        XCTAssertEqual(secondSnapshot?.stableFieldIdentity, secondIdentity)
    }

    func testTimedOutVisualCaptureClearsInFlightAndAllowsRetry() async throws {
        let privacyStore = try makePrivacyStore(PrivacySettings(screenContextEnabled: true))
        let clock = VisualContextTestClock()
        let identity = stableFieldIdentity(id: "field-a")
        let capturer = HangingFirstVisualTextCapturer(recoveryObservations: [
            VisualTextObservation(text: "Recovered context")
        ])
        let coordinator = VisualContextCoordinator(
            privacyStore: privacyStore,
            visualTextCapturer: capturer,
            screenCaptureAllowed: { true },
            captureTimeout: 0.01,
            captureFailureCooldown: 2,
            now: { clock.now }
        )

        coordinator.startIfEligible(for: textContext(identity: identity, textBeforeCursor: "Please "))
        await capturer.waitForCallCount(1)
        await waitForSessionState(.failed, coordinator: coordinator)

        XCTAssertEqual(coordinator.currentSession()?.statusMessage, "Visual context timed out")

        coordinator.startIfEligible(for: textContext(identity: identity, textBeforeCursor: "Please retry "))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(coordinator.currentSession()?.statusMessage, "Visual context cooling down after capture timeout")
        var callCount = await capturer.callCount()
        XCTAssertEqual(callCount, 1)

        clock.advance(by: 3)
        coordinator.startIfEligible(for: textContext(identity: identity, textBeforeCursor: "Please retry "))
        await capturer.waitForCallCount(2)
        await waitForSessionState(.ready, coordinator: coordinator)
        let snapshot = await coordinator.currentVisualContext(for: identity)

        XCTAssertEqual(snapshot?.summary, "Recovered context")
        callCount = await capturer.callCount()
        XCTAssertEqual(callCount, 2)
        await capturer.resumeHangingCaptures()
    }

    func testWindowScreenshotServiceCooldownSkipsCaptureAfterScreenshotTimeout() async throws {
        let clock = VisualContextTestClock()
        let cooldown = ScreenCaptureCooldown(interval: 2, now: { clock.now })
        let callCounter = LockedCounter()
        let service = WindowScreenshotService(
            timeout: 0.01,
            screenCaptureCooldown: cooldown,
            isCaptureAvailable: { true },
            screenFrameProvider: {
                CGRect(x: 0, y: 0, width: 10, height: 10)
            },
            captureImage: { _, complete in
                let callCount = callCounter.increment()
                if callCount > 1 {
                    complete(Self.makeTestImage())
                }
            }
        )

        let firstImage = await service.capturePrimaryScreenImage()
        let secondImage = await service.capturePrimaryScreenImage()
        clock.advance(by: 3)
        let thirdImage = await service.capturePrimaryScreenImage()

        XCTAssertNil(firstImage)
        XCTAssertNil(secondImage)
        XCTAssertNotNil(thirdImage)
        XCTAssertEqual(callCounter.value, 2)
    }

    func testCurrentVisualContextOnlyReadsCacheWithoutCapturing() async throws {
        let privacyStore = try makePrivacyStore(PrivacySettings(screenContextEnabled: true))
        let identity = stableFieldIdentity(id: "field-a")
        let capturer = RecordingVisualTextCapturer(observations: [
            VisualTextObservation(text: "Visible document")
        ])
        let coordinator = VisualContextCoordinator(
            privacyStore: privacyStore,
            visualTextCapturer: capturer,
            screenCaptureAllowed: { true }
        )

        let snapshot = await coordinator.currentVisualContext(for: identity)

        XCTAssertNil(snapshot)
        let callCount = await capturer.callCount()
        XCTAssertEqual(callCount, 0)
    }

    func testSameFieldTypingDoesNotRefreshVisualContext() async throws {
        let privacyStore = try makePrivacyStore(PrivacySettings(screenContextEnabled: true))
        let identity = stableFieldIdentity(id: "field-a")
        let capturer = RecordingVisualTextCapturer(observations: [
            VisualTextObservation(text: "Visible document")
        ])
        let coordinator = VisualContextCoordinator(
            privacyStore: privacyStore,
            visualTextCapturer: capturer,
            screenCaptureAllowed: { true }
        )

        coordinator.refreshOnFocusOrWindowChange(textContext(identity: identity, textBeforeCursor: "Please "))
        await capturer.waitForCallCount(1)
        coordinator.refreshOnFocusOrWindowChange(textContext(identity: identity, textBeforeCursor: "Please keep typing "))
        try await Task.sleep(nanoseconds: 50_000_000)

        let callCount = await capturer.callCount()
        XCTAssertEqual(callCount, 1)
    }

    func testRefreshTickUsesSlowTimerInterval() async throws {
        let privacyStore = try makePrivacyStore(PrivacySettings(screenContextEnabled: true))
        let clock = VisualContextTestClock()
        let identity = stableFieldIdentity(id: "field-a")
        let capturer = QueueVisualTextCapturer(queues: [
            [VisualTextObservation(text: "First visual context")],
            [VisualTextObservation(text: "Second visual context")]
        ])
        let coordinator = VisualContextCoordinator(
            privacyStore: privacyStore,
            visualTextCapturer: capturer,
            screenCaptureAllowed: { true },
            refreshInterval: 4,
            now: { clock.now }
        )

        coordinator.startIfEligible(for: textContext(identity: identity, textBeforeCursor: "Please "))
        await capturer.waitForCallCount(1)
        clock.advance(by: 3)
        coordinator.refreshTick()
        try await Task.sleep(nanoseconds: 50_000_000)
        let earlyCallCount = await capturer.callCount()
        XCTAssertEqual(earlyCallCount, 1)

        clock.advance(by: 2)
        coordinator.refreshTick()
        await capturer.waitForCallCount(2)
        await waitForSessionState(.ready, coordinator: coordinator)
        let snapshot = await coordinator.currentVisualContext(for: identity)

        XCTAssertEqual(snapshot?.summary, "Second visual context")
    }

    private static func makeTestImage() -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            XCTFail("Failed to create test bitmap context")
            fatalError("Failed to create test bitmap context")
        }
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let image = context.makeImage() else {
            XCTFail("Failed to create test image")
            fatalError("Failed to create test image")
        }
        return image
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

    private func textContext(identity: StableFieldIdentity, textBeforeCursor: String) -> TextContext {
        let app = AppIdentity(bundleID: identity.bundleID, displayName: "TextEdit", processID: identity.processID)
        return TextContext(
            app: app,
            domain: identity.domain,
            focusedElementID: "field-\(identity.focusChangeSequence ?? 0)",
            stableFieldIdentity: identity,
            textBeforeCursor: textBeforeCursor,
            focusedElementRect: identity.roundedFocusedElementFrame
        )
    }

    private func waitForSessionState(
        _ state: VisualContextSessionState,
        coordinator: VisualContextCoordinator,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let deadline = Date().addingTimeInterval(1)
        while Date() < deadline {
            if coordinator.currentSession()?.state == state {
                return
            }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Timed out waiting for visual context state \(state.rawValue)", file: file, line: line)
    }
}

private final class LockedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue = 0

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        storedValue += 1
        return storedValue
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

    func waitForCallCount(_ count: Int) async {
        while storedCallCount < count {
            await Task.yield()
        }
    }

    func captureVisibleText() async -> [VisualTextObservation] {
        storedCallCount += 1
        return observations
    }
}

private actor QueueVisualTextCapturer: VisualTextCapturing {
    private var queues: [[VisualTextObservation]]
    private var storedCallCount = 0

    init(queues: [[VisualTextObservation]]) {
        self.queues = queues
    }

    func callCount() -> Int {
        storedCallCount
    }

    func waitForCallCount(_ count: Int) async {
        while storedCallCount < count {
            await Task.yield()
        }
    }

    func captureVisibleText() async -> [VisualTextObservation] {
        storedCallCount += 1
        guard !queues.isEmpty else {
            return []
        }
        return queues.removeFirst()
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

private actor HangingFirstVisualTextCapturer: VisualTextCapturing {
    private let recoveryObservations: [VisualTextObservation]
    private var storedCallCount = 0
    private var hangingContinuations: [CheckedContinuation<[VisualTextObservation], Never>] = []

    init(recoveryObservations: [VisualTextObservation]) {
        self.recoveryObservations = recoveryObservations
    }

    func captureVisibleText() async -> [VisualTextObservation] {
        storedCallCount += 1
        if storedCallCount == 1 {
            return await withCheckedContinuation { continuation in
                hangingContinuations.append(continuation)
            }
        }
        return recoveryObservations
    }

    func waitForCallCount(_ count: Int) async {
        while storedCallCount < count {
            await Task.yield()
        }
    }

    func callCount() -> Int {
        storedCallCount
    }

    func resumeHangingCaptures() {
        let continuations = hangingContinuations
        hangingContinuations.removeAll()
        for continuation in continuations {
            continuation.resume(returning: [])
        }
    }
}

private final class VisualContextTestClock: @unchecked Sendable {
    private(set) var now = Date(timeIntervalSince1970: 5_000)

    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }
}
