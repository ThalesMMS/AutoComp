import AutoCompBenchKit
import AutoCompCore
import XCTest

final class StreamingBenchTests: XCTestCase {
    func testDeterministicCorpusShowsLatencyGainWithoutWrongShows() {
        let context = TextContext(
            app: .init(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: "Say ",
            textAfterCursor: ""
        )
        let latencies = [(20, 100), (30, 130), (40, 160), (50, 190)]
        let cases = latencies.enumerated().map { index, latency in
            StreamingBenchCase(
                id: "stream-\(index)",
                context: context,
                expectedFinal: "hello world",
                partials: [
                    .init(text: "hel", sequence: 1, latencyMs: latency.0),
                    .init(text: "hex", sequence: 2, latencyMs: latency.0 + 5),
                    .init(text: "hello", sequence: 3, latencyMs: latency.0 + 10),
                    .init(text: "hello world", sequence: 4, latencyMs: latency.1, isFinal: true)
                ]
            )
        }

        let metrics = StreamingBenchRunner().run(cases: cases)

        XCTAssertEqual(metrics.cases, 4)
        XCTAssertEqual(metrics.timeToFirstSafePartialP50Ms, 30)
        XCTAssertEqual(metrics.timeToFirstSafePartialP95Ms, 50)
        XCTAssertEqual(metrics.timeToFinalP50Ms, 130)
        XCTAssertEqual(metrics.timeToFinalP95Ms, 190)
        XCTAssertEqual(metrics.perceivedLatencyGainP50Ms, 100)
        XCTAssertEqual(metrics.perceivedLatencyGainP95Ms, 140)
        XCTAssertEqual(metrics.wrongShowRate, 0)
        XCTAssertEqual(metrics.ignoredPartials, 4)
    }
}
