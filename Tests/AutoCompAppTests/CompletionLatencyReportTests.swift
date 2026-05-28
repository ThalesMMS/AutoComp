@testable import AutoCompApp
import XCTest

final class CompletionLatencyReportTests: XCTestCase {
    func testStageRowsExposeEveryLatencyMetricWithoutContent() {
        let report = CompletionLatencyReport(
            axCaptureMs: 3,
            geometryMs: nil,
            visualContextMs: 5,
            clipboardFilterMs: 1,
            debounceMs: 250,
            backendMs: 40,
            normalizationMs: 2,
            overlayMs: 4,
            insertionMs: 7,
            totalMs: 312
        )

        XCTAssertEqual(report.stageRows.map(\.key), [
            "axCaptureMs",
            "geometryMs",
            "visualContextMs",
            "clipboardFilterMs",
            "debounceMs",
            "backendMs",
            "normalizationMs",
            "overlayMs",
            "insertionMs",
            "totalMs"
        ])
        XCTAssertEqual(report.stageRows.first { $0.key == "axCaptureMs" }?.diagnosticValue, "3 ms")
        XCTAssertEqual(report.stageRows.first { $0.key == "geometryMs" }?.diagnosticValue, "not measured")

        let redactedReport = report.redactedReport
        XCTAssertTrue(redactedReport.contains("axCaptureMs=3"))
        XCTAssertTrue(redactedReport.contains("geometryMs=not-measured"))
        XCTAssertTrue(redactedReport.contains("totalMs=312"))
        XCTAssertFalse(redactedReport.contains("typed secret"))
        XCTAssertFalse(redactedReport.contains("prompt text"))
        XCTAssertFalse(redactedReport.contains("clipboard text"))
        XCTAssertFalse(redactedReport.contains("com.apple.TextEdit"))
    }

    func testInsertionLatencyClampsNegativeInput() {
        let report = CompletionLatencyReport(backendMs: 12)
            .withInsertionLatency(-10)

        XCTAssertEqual(report.backendMs, 12)
        XCTAssertEqual(report.insertionMs, 0)
    }
}
