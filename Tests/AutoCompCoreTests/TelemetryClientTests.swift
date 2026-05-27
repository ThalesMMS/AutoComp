import AutoCompCore
import Foundation
import XCTest

final class TelemetryClientTests: XCTestCase {
    func testTelemetryClientIsOffByDefault() {
        let sink = RecordingTelemetrySink()
        let client = RedactingTelemetryClient(sink: sink)

        client.capture(sampleInput())

        XCTAssertTrue(sink.events().isEmpty)
    }

    func testRedactionDropsSensitiveContextAndHashesBundleID() throws {
        let event = TelemetryRedactor.sanitizedEvent(from: sampleInput())
        let encoded = String(data: try JSONEncoder().encode(event), encoding: .utf8) ?? ""

        XCTAssertEqual(event.name, "remote-backend-probe-failed")
        XCTAssertEqual(event.appVersion, "1.2.3")
        XCTAssertEqual(event.buildNumber, "45")
        XCTAssertEqual(event.backendKind, .remote)
        XCTAssertEqual(event.technicalError, TelemetryTechnicalError(category: "remote-backend-probe", code: "timeout"))
        XCTAssertEqual(event.permissionStatuses["accessibility"], "granted")
        XCTAssertEqual(event.permissionStatuses["inputMonitoring"], "denied")
        XCTAssertEqual(event.bundleIDHash, TelemetryRedactor.hashedIdentifier("com.example.Writer"))
        XCTAssertFalse(encoded.contains("SECRET"))
        XCTAssertFalse(encoded.contains("textBeforeCursor"))
        XCTAssertFalse(encoded.contains("textAfterCursor"))
        XCTAssertFalse(encoded.contains("clipboard"))
        XCTAssertFalse(encoded.contains("https://example.com/private/path"))
        XCTAssertFalse(encoded.contains("example.com"))
    }

    func testDisableAndDeleteStopSendingImmediately() {
        let sink = RecordingTelemetrySink()
        let client = RedactingTelemetryClient(enabled: true, sink: sink)

        client.capture(sampleInput(name: "first-error"))
        client.setEnabled(false)
        client.capture(sampleInput(name: "second-error"))

        XCTAssertEqual(sink.events().map(\.name), ["first-error"])
        XCTAssertEqual(sink.deleteAllCallCount(), 1)

        client.deleteAll()
        client.capture(sampleInput(name: "third-error"))

        XCTAssertEqual(sink.events().map(\.name), ["first-error"])
        XCTAssertEqual(sink.deleteAllCallCount(), 2)
    }

    func testDisabledTelemetryClientIgnoresEnableAndCapture() {
        let client = DisabledTelemetryClient()

        client.setEnabled(true)
        client.capture(sampleInput())
        client.deleteAll()
    }

    private func sampleInput(name: String = "remote-backend-probe-failed") -> TelemetryEventInput {
        TelemetryEventInput(
            name: name,
            appVersion: "1.2.3",
            buildNumber: "45",
            backendKind: .remote,
            technicalError: TelemetryTechnicalError(category: "remote-backend-probe", code: "timeout"),
            permissionStatuses: [
                .accessibility: .granted,
                .inputMonitoring: .denied
            ],
            bundleID: "com.example.Writer",
            prompt: "SECRET prompt",
            textBeforeCursor: "SECRET before",
            textAfterCursor: "SECRET after",
            clipboard: "SECRET clipboard",
            ocrText: "SECRET OCR",
            screenshotDescription: "SECRET screenshot",
            suggestion: "SECRET suggestion",
            url: "https://example.com/private/path?token=SECRET",
            domain: "example.com"
        )
    }
}

private final class RecordingTelemetrySink: TelemetryEventSink, @unchecked Sendable {
    private let lock = NSLock()
    private var storedEvents: [TelemetryEvent] = []
    private var storedDeleteAllCallCount = 0

    func send(_ event: TelemetryEvent) {
        lock.lock()
        storedEvents.append(event)
        lock.unlock()
    }

    func deleteAll() {
        lock.lock()
        storedDeleteAllCallCount += 1
        lock.unlock()
    }

    func events() -> [TelemetryEvent] {
        lock.lock()
        defer { lock.unlock() }
        return storedEvents
    }

    func deleteAllCallCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return storedDeleteAllCallCount
    }
}
