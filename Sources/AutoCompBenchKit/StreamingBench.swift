import AutoCompCore
import Foundation

public struct StreamingBenchPartial: Equatable, Sendable {
    public let text: String
    public let sequence: Int
    public let latencyMs: Int
    public let isFinal: Bool

    public init(text: String, sequence: Int, latencyMs: Int, isFinal: Bool = false) {
        self.text = text
        self.sequence = sequence
        self.latencyMs = latencyMs
        self.isFinal = isFinal
    }
}

public struct StreamingBenchCase: Equatable, Sendable {
    public let id: String
    public let context: TextContext
    public let expectedFinal: String
    public let partials: [StreamingBenchPartial]

    public init(id: String, context: TextContext, expectedFinal: String, partials: [StreamingBenchPartial]) {
        self.id = id
        self.context = context
        self.expectedFinal = expectedFinal
        self.partials = partials
    }
}

public struct StreamingBenchMetrics: Equatable, Sendable {
    public let cases: Int
    public let timeToFirstSafePartialP50Ms: Int
    public let timeToFirstSafePartialP95Ms: Int
    public let timeToFinalP50Ms: Int
    public let timeToFinalP95Ms: Int
    public let perceivedLatencyGainP50Ms: Int
    public let perceivedLatencyGainP95Ms: Int
    public let wrongShowRate: Double
    public let renderedPartials: Int
    public let ignoredPartials: Int
}

public struct StreamingBenchRunner: Sendable {
    public init() {}

    public func run(cases: [StreamingBenchCase]) -> StreamingBenchMetrics {
        var firstSafe: [Int] = []
        var finals: [Int] = []
        var gains: [Int] = []
        var rendered = 0
        var ignored = 0
        var wrongShows = 0

        for benchmarkCase in cases {
            var policy = StreamedSuggestionPolicy()
            let metadata = StreamingCompletionMetadata(
                traceContext: CompletionTraceContext(),
                workID: 1,
                requestedRoute: .localLlama
            )
            var firstLatency: Int?
            var finalLatency: Int?
            for fixture in benchmarkCase.partials {
                let partial = CompletionPartial(
                    metadata: metadata,
                    accumulatedText: fixture.text,
                    providerSequence: fixture.sequence,
                    route: CompletionRoute(requestedKind: .localLlama, deliveredKind: .localLlama),
                    phase: fixture.isFinal ? .final : .partial,
                    latencyMs: fixture.latencyMs
                )
                switch policy.evaluate(partial, context: benchmarkCase.context) {
                case .render(let text):
                    rendered += 1
                    firstLatency = firstLatency ?? fixture.latencyMs
                    if !benchmarkCase.expectedFinal.hasPrefix(text) { wrongShows += 1 }
                case .ignore, .keepCurrent, .hide:
                    ignored += 1
                case .finalizeCurrent:
                    break
                }
                if fixture.isFinal { finalLatency = fixture.latencyMs }
            }
            if let firstLatency { firstSafe.append(firstLatency) }
            if let finalLatency { finals.append(finalLatency) }
            if let firstLatency, let finalLatency { gains.append(max(0, finalLatency - firstLatency)) }
        }

        return StreamingBenchMetrics(
            cases: cases.count,
            timeToFirstSafePartialP50Ms: percentile(firstSafe, 0.50),
            timeToFirstSafePartialP95Ms: percentile(firstSafe, 0.95),
            timeToFinalP50Ms: percentile(finals, 0.50),
            timeToFinalP95Ms: percentile(finals, 0.95),
            perceivedLatencyGainP50Ms: percentile(gains, 0.50),
            perceivedLatencyGainP95Ms: percentile(gains, 0.95),
            wrongShowRate: rendered == 0 ? 0 : Double(wrongShows) / Double(rendered),
            renderedPartials: rendered,
            ignoredPartials: ignored
        )
    }

    private func percentile(_ values: [Int], _ percentile: Double) -> Int {
        guard !values.isEmpty else { return 0 }
        let sorted = values.sorted()
        let index = Int(ceil(Double(sorted.count) * percentile)) - 1
        return sorted[min(max(index, 0), sorted.count - 1)]
    }
}
