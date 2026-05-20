import AutoCompCore
@testable import AutoCompApp
import XCTest

final class VisualContextCoordinatorTests: XCTestCase {
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
        let capturer = RecordingVisualTextCapturer(observations: [
            VisualTextObservation(text: "Visible document")
        ])
        let coordinator = VisualContextCoordinator(
            privacyStore: privacyStore,
            visualTextCapturer: capturer,
            screenCaptureAllowed: { false }
        )

        let snapshot = await coordinator.currentVisualContext()

        XCTAssertNil(snapshot)
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
        let capturer = RecordingVisualTextCapturer(observations: [
            VisualTextObservation(text: "  Budget   review  "),
            VisualTextObservation(text: "Budget review"),
            VisualTextObservation(text: "Q3\tforecast", captureSource: .screenOCR),
            VisualTextObservation(text: String(repeating: "x", count: 160), captureSource: .screenOCR)
        ])
        let coordinator = VisualContextCoordinator(
            privacyStore: privacyStore,
            visualTextCapturer: capturer,
            screenCaptureAllowed: { true },
            maxSummaryCharacters: 90
        )

        let resolvedSnapshot = await coordinator.currentVisualContext()
        let snapshot = try XCTUnwrap(resolvedSnapshot)

        XCTAssertLessThanOrEqual(snapshot.summary.count, 90)
        XCTAssertTrue(snapshot.summary.hasPrefix("Budget review\nQ3 forecast"))
        XCTAssertEqual(snapshot.captureSources, [.screenOCR])
    }

    private func makePrivacyStore(_ settings: PrivacySettings) throws -> PrivacySettingsStore {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AutoCompVisualContext-\(UUID().uuidString)"))
        let store = PrivacySettingsStore(defaults: defaults, key: "privacy")
        try store.save(settings)
        return store
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
