import Foundation

public enum BenchIOError: LocalizedError {
    case invalidJSONL(URL, Int, Error)
    case nonSyntheticFixture(String)

    public var errorDescription: String? {
        switch self {
        case .invalidJSONL(let url, let line, let error): return "Invalid JSONL at \(url.path):\(line): \(error)"
        case .nonSyntheticFixture(let id): return "Committed fixture \(id) is not marked synthetic"
        }
    }
}

public enum BenchIO {
    public static func loadJSONL(at url: URL, requireSynthetic: Bool = true) throws -> [BenchCase] {
        let text = try String(contentsOf: url, encoding: .utf8)
        let decoder = JSONDecoder()
        return try text.split(
            omittingEmptySubsequences: false,
            whereSeparator: \.isNewline
        ).enumerated().compactMap { offset, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#") else { return nil }
            do {
                let testCase = try decoder.decode(BenchCase.self, from: Data(trimmed.utf8))
                if requireSynthetic && !testCase.synthetic { throw BenchIOError.nonSyntheticFixture(testCase.id) }
                return testCase
            } catch let error as BenchIOError { throw error }
            catch { throw BenchIOError.invalidJSONL(url, offset + 1, error) }
        }
    }

    public static func loadDirectory(_ url: URL, suite: String? = nil) throws -> [BenchCase] {
        let files = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
        let cases = try files.flatMap { try loadJSONL(at: $0) }
        guard let suite, suite != "all" else { return cases }
        return cases.filter { $0.suite == suite }
    }

    public static func json(_ report: BenchReport) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(report)
    }

    public static func markdown(_ report: BenchReport) -> String {
        let m = report.metrics
        var lines = [
            "# AutoCompBench report",
            "", "- Mode: `\(report.mode)`", "- Configuration: `\(report.configuration.id)`",
            "- Manifest commit: `\(report.manifestCommit)`", "- Cases: \(m.cases) (\(m.evaluated) evaluated, \(m.skipped) skipped)", "",
            "| Metric | Value |", "| --- | ---: |",
            "| Correct show | \(m.correctShow) |", "| Wrong show | \(m.wrongShow) |",
            "| Correct suppression | \(m.correctSuppression) |", "| Incorrect suppression | \(m.incorrectSuppression) |",
            "| Wrong-show rate | \(percent(m.wrongShowRate)) |", "| Precision when shown | \(percent(m.shownPrecision)) |",
            "| Positive coverage | \(percent(m.positiveCoverage)) |", "| Duplicate-after-cursor rate | \(percent(m.duplicateAfterCursorRate)) |",
            "| Stale-publication rate | \(percent(m.stalePublicationRate)) |", "| Provider latency p50 / p95 | \(m.latencyP50Ms) / \(m.latencyP95Ms) ms |",
            "| Provider calls | \(m.providerCalls) |", "| Prefill bytes / tokens | \(m.prefillBytes) / \(m.prefillTokens) |",
            "| Scheduling cases / mismatches | \(m.schedulingCases) / \(m.schedulingMismatches) |",
            "| Reuse cases / mismatches | \(m.reuseCases) / \(m.reuseMismatches) |",
            "| Reuse promotion / rollback hits | \(m.reusePromotionHits) / \(m.reuseRollbackHits) |",
            "| Provider calls skipped by reuse | \(m.providerCallsSkippedByReuse) |",
            "| Speculation cases / mismatches | \(m.speculationCases) / \(m.speculationMismatches) |",
            "| Speculation validated / diverged | \(m.speculationValidated) / \(m.speculationDiverged) |",
            "| Target / remaining debounce p50 | \(m.targetDebounceP50Ms) / \(m.remainingDebounceP50Ms) ms |", ""
        ]
        let failures = report.results.filter { $0.classification == .wrongShow || $0.classification == .incorrectSuppression }
        if !failures.isEmpty {
            lines += ["## Regressions", "", "| Case | Classification | Reason |", "| --- | --- | --- |"]
            lines += failures.map { "| `\($0.id)` | \($0.classification.rawValue) | \($0.reason) |" }
            lines.append("")
        }
        let skips = report.results.filter { $0.classification == .skipped }
        if !skips.isEmpty {
            lines += ["## Structured skips", ""] + skips.map { "- `\($0.id)`: \($0.reason)" } + [""]
        }
        lines += ["## By tag", "", "| Tag | Evaluated | Wrong show | Coverage |", "| --- | ---: | ---: | ---: |"]
        lines += report.byTag.map { "| `\($0.key)` | \($0.metrics.evaluated) | \($0.metrics.wrongShow) | \(percent($0.metrics.positiveCoverage)) |" }
        lines += groupMarkdown(title: "By backend", label: "Backend", groups: report.byBackend)
        lines += groupMarkdown(title: "By model row", label: "Model row", groups: report.byModelRow)
        if let comparison = report.baselineComparison {
            lines += ["", "## Baseline diff", "", "- Baseline manifest: `\(comparison.baselineManifestCommit)`"]
            lines += comparison.regressions.isEmpty
                ? ["- No scoring regressions."]
                : comparison.regressions.map { "- Regression: \($0)" }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func regressionMessages(report: BenchReport, baseline: BenchReport) -> [String] {
        var messages: [String] = []
        if report.metrics.wrongShow > baseline.metrics.wrongShow { messages.append("wrongShow increased") }
        if report.metrics.incorrectSuppression > baseline.metrics.incorrectSuppression { messages.append("incorrectSuppression increased") }
        if report.metrics.correctShow < baseline.metrics.correctShow { messages.append("correctShow decreased") }
        if report.metrics.correctSuppression < baseline.metrics.correctSuppression { messages.append("correctSuppression decreased") }
        if report.metrics.duplicateAfterCursorRate > baseline.metrics.duplicateAfterCursorRate { messages.append("duplicateAfterCursorRate increased") }
        if report.metrics.stalePublicationRate > baseline.metrics.stalePublicationRate { messages.append("stalePublicationRate increased") }
        if report.metrics.schedulingMismatches > baseline.metrics.schedulingMismatches { messages.append("schedulingMismatches increased") }
        if report.metrics.reuseMismatches > baseline.metrics.reuseMismatches { messages.append("reuseMismatches increased") }
        if report.metrics.speculationMismatches > baseline.metrics.speculationMismatches { messages.append("speculationMismatches increased") }
        return messages
    }

    private static func groupMarkdown(title: String, label: String, groups: [BenchGroup]) -> [String] {
        ["", "## \(title)", "", "| \(label) | Evaluated | Wrong show | Coverage |", "| --- | ---: | ---: | ---: |"]
            + groups.map { "| `\($0.key)` | \($0.metrics.evaluated) | \($0.metrics.wrongShow) | \(percent($0.metrics.positiveCoverage)) |" }
    }

    public static func abMarkdown(_ lhs: BenchReport, _ rhs: BenchReport) -> String {
        """
        # AutoCompBench A/B delta

        | Metric | \(lhs.configuration.id) | \(rhs.configuration.id) | Delta B-A |
        | --- | ---: | ---: | ---: |
        | Correct show | \(lhs.metrics.correctShow) | \(rhs.metrics.correctShow) | \(rhs.metrics.correctShow - lhs.metrics.correctShow) |
        | Wrong show | \(lhs.metrics.wrongShow) | \(rhs.metrics.wrongShow) | \(rhs.metrics.wrongShow - lhs.metrics.wrongShow) |
        | Correct suppression | \(lhs.metrics.correctSuppression) | \(rhs.metrics.correctSuppression) | \(rhs.metrics.correctSuppression - lhs.metrics.correctSuppression) |
        | Positive coverage | \(percent(lhs.metrics.positiveCoverage)) | \(percent(rhs.metrics.positiveCoverage)) | \(percent(rhs.metrics.positiveCoverage - lhs.metrics.positiveCoverage)) |

        ## Deltas by tag

        \(tagDeltas(lhs, rhs))
        """
    }

    private static func tagDeltas(_ lhs: BenchReport, _ rhs: BenchReport) -> String {
        let left = Dictionary(uniqueKeysWithValues: lhs.byTag.map { ($0.key, $0.metrics) })
        let right = Dictionary(uniqueKeysWithValues: rhs.byTag.map { ($0.key, $0.metrics) })
        let rows = Set(left.keys).union(right.keys).sorted().map { key in
            "| `\(key)` | \(left[key]?.wrongShow ?? 0) | \(right[key]?.wrongShow ?? 0) | \((right[key]?.positiveCoverage ?? 0) - (left[key]?.positiveCoverage ?? 0)) |"
        }
        return (["| Tag | Wrong show A | Wrong show B | Coverage delta |", "| --- | ---: | ---: | ---: |"] + rows).joined(separator: "\n")
    }

    private static func percent(_ value: Double) -> String { String(format: "%.2f%%", value * 100) }
}
