import AutoCompBenchKit
import AutoCompCore
import XCTest

final class BenchRunnerTests: XCTestCase {
    func testJSONLErrorReportsOriginalLineAfterBlankRecord() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("autocomp-bench-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: url) }
        try "# comment\n\nnot-json\n".write(to: url, atomically: true, encoding: .utf8)

        XCTAssertThrowsError(try BenchIO.loadJSONL(at: url)) { error in
            guard case .invalidJSONL(_, let line, _) = error as? BenchIOError else {
                return XCTFail("Expected invalid JSONL error, got \(error)")
            }
            XCTAssertEqual(line, 3)
        }
    }

    func testCommittedDatasetsAreSyntheticAndCoverRequiredSuitesAndTags() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let packageRoot = testsDirectory.deletingLastPathComponent().deletingLastPathComponent()
        let cases = try BenchIO.loadDirectory(packageRoot.appendingPathComponent("Benchmarks/Datasets"))

        XCTAssertEqual(Set(cases.map(\.suite)), ["smoke", "core", "edge", "policy", "latency"])
        XCTAssertTrue(cases.allSatisfy(\.synthetic))
        let tags = Set(cases.flatMap(\.tags))
        for tag in [
            "append/end", "mid-word", "FIM", "suffix-duplicate", "prompt/suffix-echo",
            "whitespace", "selection", "Unicode", "risky-chat", "code/terminal-disabled",
            "stale", "insufficient-geometry"
        ] {
            XCTAssertTrue(tags.contains(tag), "Missing required benchmark tag: \(tag)")
        }
    }

    func testFixtureRunnerUsesProductionNormalizerAndScoresShow() async {
        let testCase = BenchCase(
            id: "echo", beforeCursor: "Hello ", afterCursor: "world",
            fixtureOutput: "Hello beautiful world", expected: .show,
            acceptableContinuations: ["beautiful"], tags: ["suffix-echo"]
        )
        let report = await BenchRunner().run(cases: [testCase], provider: FixtureBenchProvider())
        XCTAssertEqual(report.metrics.correctShow, 1)
        XCTAssertEqual(report.metrics.duplicateAfterCursorRate, 0)
    }

    func testIdentityABDetectsArtificialNormalizerRegression() async {
        let testCase = BenchCase(
            id: "suffix", beforeCursor: "Hello ", afterCursor: "world",
            fixtureOutput: "beautiful world", expected: .show,
            acceptableContinuations: ["beautiful"], forbiddenPatterns: ["world"], tags: ["suffix-duplicate"]
        )
        let runner = BenchRunner()
        let production = await runner.run(cases: [testCase], provider: FixtureBenchProvider())
        let identity = await runner.run(
            cases: [testCase], provider: FixtureBenchProvider(),
            configuration: BenchConfiguration(id: "identity", normalization: .identity)
        )
        XCTAssertEqual(production.metrics.correctShow, 1)
        XCTAssertEqual(identity.metrics.wrongShow, 1)
        XCTAssertTrue(BenchIO.abMarkdown(production, identity).contains("suffix-duplicate"))
        let regressions = BenchIO.regressionMessages(report: identity, baseline: production)
        XCTAssertTrue(regressions.contains("wrongShow increased"))
        XCTAssertTrue(regressions.contains("correctShow decreased"))
        XCTAssertTrue(regressions.contains("duplicateAfterCursorRate increased"))
    }

    func testStaleSuggestionIsSuppressedByRealGuardrail() async {
        let testCase = BenchCase(
            id: "stale", beforeCursor: "Hello ", fixtureOutput: "world", expected: .suppress,
            tags: ["stale"], suggestionAgeMs: 13_000
        )
        let report = await BenchRunner().run(cases: [testCase], provider: FixtureBenchProvider())
        XCTAssertEqual(report.metrics.correctSuppression, 1)
        XCTAssertEqual(report.results.first?.reason, "guardrail:stale")
    }

    func testReportsContainNoPromptOrCompletionText() async throws {
        let secret = "PRIVATE_SENTINEL_123"
        let testCase = BenchCase(
            id: "privacy", beforeCursor: secret, fixtureOutput: secret, expected: .show,
            acceptableContinuations: [secret], tags: ["privacy"]
        )
        let report = await BenchRunner().run(cases: [testCase], provider: FixtureBenchProvider())
        let json = String(data: try BenchIO.json(report), encoding: .utf8) ?? ""
        XCTAssertFalse(json.contains(secret))
        XCTAssertFalse(BenchIO.markdown(report).contains(secret))
    }

    func testLocalLiveSkipIsStructured() async {
        let testCase = BenchCase(id: "local", beforeCursor: "Hello ", expected: .show, tags: ["live"])
        let report = await BenchRunner().run(
            cases: [testCase], provider: SkippingBenchProvider(reason: .localRuntimeUnavailable), mode: "local-live"
        )
        XCTAssertEqual(report.metrics.skipped, 1)
        XCTAssertEqual(report.results.first?.skipReason, .localRuntimeUnavailable)
    }

    func testReportIncludesBackendModelGroupsAndBaselineDiff() async {
        let testCase = BenchCase(
            id: "groups", beforeCursor: "Hello ", backend: "test-backend", modelRow: "test-model",
            fixtureOutput: "world", expected: .show, acceptableContinuations: ["world"], tags: ["group"]
        )
        var report = await BenchRunner().run(cases: [testCase], provider: FixtureBenchProvider())
        report.baselineComparison = BenchBaselineComparison(
            baselineManifestCommit: "abc123", regressions: []
        )
        let markdown = BenchIO.markdown(report)
        XCTAssertTrue(markdown.contains("## By backend"))
        XCTAssertTrue(markdown.contains("`test-backend`"))
        XCTAssertTrue(markdown.contains("## By model row"))
        XCTAssertTrue(markdown.contains("`test-model`"))
        XCTAssertTrue(markdown.contains("No scoring regressions"))
    }

    func testLatencySuiteMeasuresAdaptiveSchedulingByRoute() async throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let packageRoot = testsDirectory.deletingLastPathComponent().deletingLastPathComponent()
        let cases = try BenchIO.loadDirectory(
            packageRoot.appendingPathComponent("Benchmarks/Datasets"),
            suite: "latency"
        )

        let report = await BenchRunner().run(cases: cases, provider: FixtureBenchProvider())

        XCTAssertEqual(report.metrics.schedulingCases, 3)
        XCTAssertEqual(report.metrics.schedulingMismatches, 0)
        XCTAssertEqual(report.metrics.targetDebounceP50Ms, 140)
        XCTAssertEqual(report.metrics.remainingDebounceP50Ms, 50)
        XCTAssertEqual(Set(report.results.compactMap { $0.scheduling?.route }), Set(CompletionEngineKind.allCases))
        XCTAssertEqual(report.metrics.reuseCases, 3)
        XCTAssertEqual(report.metrics.reuseMismatches, 0)
        XCTAssertEqual(report.metrics.reusePromotionHits, 1)
        XCTAssertEqual(report.metrics.reuseRollbackHits, 1)
        XCTAssertEqual(report.metrics.providerCallsSkippedByReuse, 2)
        XCTAssertEqual(report.metrics.speculationCases, 3)
        XCTAssertEqual(report.metrics.speculationMismatches, 0)
        XCTAssertEqual(report.metrics.speculationValidated, 1)
        XCTAssertEqual(report.metrics.speculationDiverged, 1)
    }
}
