import AutoCompCore
import CoreGraphics
import Foundation

public enum BenchClassification: String, Codable, Sendable {
    case correctShow, wrongShow, correctSuppression, incorrectSuppression, skipped
}

public struct BenchSchedulingMeasurement: Codable, Equatable, Sendable {
    public let route: CompletionEngineKind
    public let targetDebounceMs: Int
    public let remainingDebounceMs: Int
    public let action: SuggestionSchedulingAction
    public let reason: SuggestionSchedulingReason
    public let matchesExpectation: Bool
}

public struct BenchReuseMeasurement: Codable, Equatable, Sendable {
    public let route: CompletionEngineKind
    public let action: BenchReuseExpectedAction
    public let sourceRank: Int?
    public let remainingCharacters: Int?
    public let providerCallSkipped: Bool
    public let matchesExpectation: Bool
}

public struct BenchSpeculationMeasurement: Codable, Equatable, Sendable {
    public let route: CompletionEngineKind
    public let action: BenchSpeculationExpectedAction
    public let signatureMatched: Bool
    public let matchesExpectation: Bool
}

public struct BenchCaseResult: Codable, Equatable, Sendable {
    public let id: String
    public let suite: String
    public let tags: [String]
    public let backend: String
    public let modelRow: String
    public let expected: BenchExpectedDecision
    public let classification: BenchClassification
    public let reason: String
    public let shown: Bool
    public let duplicateAfterCursor: Bool
    public let stalePublication: Bool
    public let providerCalled: Bool
    public let latencyMs: Int
    public let prefillBytes: Int
    public let prefillTokens: Int
    public let skipReason: BenchSkipReason?
    public let scheduling: BenchSchedulingMeasurement?
    public let reuse: BenchReuseMeasurement?
    public let speculation: BenchSpeculationMeasurement?
}

public struct BenchMetrics: Codable, Equatable, Sendable {
    public let cases: Int
    public let evaluated: Int
    public let skipped: Int
    public let correctShow: Int
    public let wrongShow: Int
    public let correctSuppression: Int
    public let incorrectSuppression: Int
    public let wrongShowRate: Double
    public let shownPrecision: Double
    public let positiveCoverage: Double
    public let duplicateAfterCursorRate: Double
    public let stalePublicationRate: Double
    public let latencyP50Ms: Int
    public let latencyP95Ms: Int
    public let providerCalls: Int
    public let prefillBytes: Int
    public let prefillTokens: Int
    public let schedulingCases: Int
    public let schedulingMismatches: Int
    public let targetDebounceP50Ms: Int
    public let remainingDebounceP50Ms: Int
    public let reuseCases: Int
    public let reuseMismatches: Int
    public let reusePromotionHits: Int
    public let reuseRollbackHits: Int
    public let providerCallsSkippedByReuse: Int
    public let speculationCases: Int
    public let speculationMismatches: Int
    public let speculationValidated: Int
    public let speculationDiverged: Int

    public init(results: [BenchCaseResult]) {
        cases = results.count
        let active = results.filter { $0.classification != .skipped }
        evaluated = active.count; skipped = results.count - active.count
        correctShow = active.filter { $0.classification == .correctShow }.count
        wrongShow = active.filter { $0.classification == .wrongShow }.count
        correctSuppression = active.filter { $0.classification == .correctSuppression }.count
        incorrectSuppression = active.filter { $0.classification == .incorrectSuppression }.count
        let shown = active.filter(\.shown)
        let positives = active.filter { $0.expected == .show }.count
        wrongShowRate = Self.ratio(wrongShow, active.count)
        shownPrecision = Self.ratio(correctShow, shown.count)
        positiveCoverage = Self.ratio(correctShow, positives)
        duplicateAfterCursorRate = Self.ratio(shown.filter(\.duplicateAfterCursor).count, shown.count)
        stalePublicationRate = Self.ratio(active.filter(\.stalePublication).count, active.count)
        let latencies = results.filter(\.providerCalled).map(\.latencyMs).sorted()
        latencyP50Ms = Self.percentile(latencies, 0.50)
        latencyP95Ms = Self.percentile(latencies, 0.95)
        providerCalls = results.filter(\.providerCalled).count
        prefillBytes = results.reduce(0) { $0 + $1.prefillBytes }
        prefillTokens = results.reduce(0) { $0 + $1.prefillTokens }
        let scheduling = results.compactMap(\.scheduling)
        schedulingCases = scheduling.count
        schedulingMismatches = scheduling.filter { !$0.matchesExpectation }.count
        targetDebounceP50Ms = Self.percentile(scheduling.map(\.targetDebounceMs).sorted(), 0.50)
        remainingDebounceP50Ms = Self.percentile(scheduling.map(\.remainingDebounceMs).sorted(), 0.50)
        let reuse = results.compactMap(\.reuse)
        reuseCases = reuse.count
        reuseMismatches = reuse.filter { !$0.matchesExpectation }.count
        reusePromotionHits = reuse.filter { $0.action == .promoteAppend && $0.matchesExpectation }.count
        reuseRollbackHits = reuse.filter { $0.action == .restoreRollback && $0.matchesExpectation }.count
        providerCallsSkippedByReuse = reuse.filter(\.providerCallSkipped).count
        let speculation = results.compactMap(\.speculation)
        speculationCases = speculation.count
        speculationMismatches = speculation.filter { !$0.matchesExpectation }.count
        speculationValidated = speculation.filter { $0.action == .start && $0.signatureMatched }.count
        speculationDiverged = speculation.filter { $0.action == .start && !$0.signatureMatched }.count
    }

    private static func ratio(_ numerator: Int, _ denominator: Int) -> Double {
        denominator == 0 ? 0 : Double(numerator) / Double(denominator)
    }

    private static func percentile(_ values: [Int], _ percentile: Double) -> Int {
        guard !values.isEmpty else { return 0 }
        let index = Int(ceil(Double(values.count) * percentile)) - 1
        return values[min(max(index, 0), values.count - 1)]
    }
}

public struct BenchGroup: Codable, Equatable, Sendable {
    public let key: String
    public let metrics: BenchMetrics
}

public struct BenchReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let mode: String
    public let configuration: BenchConfiguration
    public let manifestCommit: String
    public let metrics: BenchMetrics
    public let byTag: [BenchGroup]
    public let byBackend: [BenchGroup]
    public let byModelRow: [BenchGroup]
    public let results: [BenchCaseResult]
    public var baselineComparison: BenchBaselineComparison?

    public init(mode: String, configuration: BenchConfiguration, manifestCommit: String, results: [BenchCaseResult]) {
        schemaVersion = 1; self.mode = mode; self.configuration = configuration
        self.manifestCommit = manifestCommit; self.results = results
        metrics = BenchMetrics(results: results)
        byTag = Self.groups(results: results, keys: Set(results.flatMap(\.tags))) { $0.tags.contains($1) }
        byBackend = Self.groups(results: results, keys: Set(results.map(\.backend))) { $0.backend == $1 }
        byModelRow = Self.groups(results: results, keys: Set(results.map(\.modelRow))) { $0.modelRow == $1 }
        baselineComparison = nil
    }

    private static func groups(
        results: [BenchCaseResult], keys: Set<String>, matches: (BenchCaseResult, String) -> Bool
    ) -> [BenchGroup] {
        keys.sorted().map { key in BenchGroup(key: key, metrics: BenchMetrics(results: results.filter { matches($0, key) })) }
    }
}

public struct BenchBaselineComparison: Codable, Equatable, Sendable {
    public let baselineManifestCommit: String
    public let regressions: [String]

    public init(baselineManifestCommit: String, regressions: [String]) {
        self.baselineManifestCommit = baselineManifestCommit
        self.regressions = regressions
    }
}

public struct BenchRunner: Sendable {
    public init() {}

    public func run(
        cases: [BenchCase],
        provider: any BenchCompletionProvider,
        configuration: BenchConfiguration = .production,
        mode: String = "fixture",
        manifestCommit: String = "unknown"
    ) async -> BenchReport {
        var results: [BenchCaseResult] = []
        for testCase in cases {
            results.append(await evaluate(testCase, provider: provider, configuration: configuration))
        }
        return BenchReport(mode: mode, configuration: configuration, manifestCommit: manifestCommit, results: results)
    }

    private func evaluate(
        _ testCase: BenchCase, provider: any BenchCompletionProvider, configuration: BenchConfiguration
    ) async -> BenchCaseResult {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let context = makeContext(testCase, now: now, live: false)
        let compatibility = CompatibilityCatalog().decision(bundleID: testCase.appBundleID, domain: testCase.domain)
        let eligibility = SuggestionEligibilityEvaluator().evaluate(
            context: context,
            previousContext: nil,
            compatibilityDecision: compatibility,
            lastSuggestionTriggerKeyAt: now,
            invocation: testCase.invocation,
            now: now
        )
        guard eligibility.isEligible else {
            return classifySuppression(testCase, reason: "eligibility:\(eligibility.skipReason?.rawValue ?? "unknown")")
        }

        let geometry = CaretGeometryTrustEvaluator.default.evaluate(
            caretRect: context.caretRect,
            focusedElementRect: context.focusedElementRect,
            screenBounds: CGRect(x: 0, y: 0, width: 1920, height: 1080),
            quality: context.caretGeometryQuality,
            provenance: context.caretGeometryProvenance ?? .unknown
        )
        guard geometry != .suppress else {
            return classifySuppression(testCase, reason: "geometry:suppress")
        }

        let sample = await provider.sample(for: testCase, configuration: configuration)
        guard let raw = sample.output else {
            return BenchCaseResult(
                id: testCase.id, suite: testCase.suite, tags: testCase.tags,
                backend: testCase.backend, modelRow: testCase.modelRow, expected: testCase.expected,
                classification: .skipped, reason: sample.skipReason?.rawValue ?? "provider-skip",
                shown: false, duplicateAfterCursor: false, stalePublication: false,
                providerCalled: false, latencyMs: 0, prefillBytes: 0, prefillTokens: 0,
                skipReason: sample.skipReason, scheduling: schedulingMeasurement(testCase),
                reuse: reuseMeasurement(testCase), speculation: speculationMeasurement(testCase)
            )
        }

        let normalized = configuration.normalization == .production
            ? SuggestionTextNormalizer.normalize(
                rawText: raw,
                precedingText: testCase.beforeCursor,
                trailingText: testCase.afterCursor
            )
            : raw
        var suggestion = Suggestion(
            baseContextID: context.id,
            visibleText: normalized,
            binding: SuggestionBinding.from(
                textContext: context,
                now: now.addingTimeInterval(-Double(testCase.suggestionAgeMs) / 1_000)
            ),
            rawText: raw,
            latencyMs: sample.latencyMs
        )

        var stalePublication = false
        if configuration.enforceLiveGuardrails {
            let live = makeContext(testCase, now: now, live: true)
            let guardrail = SuggestionGuardrailValidator.default.validateAccept(
                binding: suggestion.binding,
                currentStableFieldIdentity: live.stableFieldIdentity,
                currentFocusedElementID: live.focusedElementID,
                currentContextFingerprint: SuggestionContextFingerprint.from(textContext: live),
                now: now
            )
            guard guardrail == .allowAccept else {
                return result(
                    testCase, classification: testCase.expected == .suppress ? .correctSuppression : .incorrectSuppression,
                    reason: "guardrail:\(guardrailReason(guardrail))", shown: false, duplicate: false,
                    stale: false, sample: sample
                )
            }
        } else if testCase.suggestionAgeMs > Int(SuggestionBinding.defaultFreshnessWindow * 1_000)
                    || testCase.liveBeforeCursor != nil || testCase.liveAfterCursor != nil {
            stalePublication = true
        }

        switch SuggestionPublicationPolicy.evaluate(suggestion, for: context) {
        case .suppressEmpty:
            return result(
                testCase, classification: testCase.expected == .suppress ? .correctSuppression : .incorrectSuppression,
                reason: "publication:empty", shown: false, duplicate: false, stale: false, sample: sample
            )
        case .publish(let published):
            suggestion = published
        }

        let acceptable = isAcceptable(suggestion.visibleText, for: testCase)
        let forbidden = testCase.forbiddenPatterns.contains { suggestion.visibleText.localizedCaseInsensitiveContains($0) }
        let duplicate = isDuplicateAfterCursor(suggestion.visibleText, after: testCase.afterCursor)
        let correct = testCase.expected == .show && acceptable && !forbidden
        return result(
            testCase,
            classification: correct ? .correctShow : .wrongShow,
            reason: correct ? "acceptable" : (forbidden ? "forbidden-pattern" : "unexpected-or-unacceptable-show"),
            shown: true, duplicate: duplicate, stale: stalePublication, sample: sample
        )
    }

    private func makeContext(_ testCase: BenchCase, now: Date, live: Bool) -> TextContext {
        let caret = testCase.caretAvailable ? CGRect(x: 100, y: 100, width: 2, height: 20) : nil
        return TextContext(
            app: AppIdentity(bundleID: testCase.appBundleID, displayName: testCase.appDisplayName, processID: 1),
            domain: testCase.domain,
            focusedElementID: "bench-field",
            textBeforeCursor: live ? (testCase.liveBeforeCursor ?? testCase.beforeCursor) : testCase.beforeCursor,
            textAfterCursor: live ? (testCase.liveAfterCursor ?? testCase.afterCursor) : testCase.afterCursor,
            selectedText: testCase.selectedText,
            caretRect: caret,
            focusedElementRect: CGRect(x: 20, y: 20, width: 800, height: 600),
            caretGeometryQuality: testCase.geometryQuality,
            createdAt: now
        )
    }

    private func classifySuppression(_ testCase: BenchCase, reason: String) -> BenchCaseResult {
        result(
            testCase, classification: testCase.expected == .suppress ? .correctSuppression : .incorrectSuppression,
            reason: reason, shown: false, duplicate: false, stale: false,
            sample: BenchProviderSample(skip: .providerFailure)
        )
    }

    private func result(
        _ testCase: BenchCase, classification: BenchClassification, reason: String,
        shown: Bool, duplicate: Bool, stale: Bool, sample: BenchProviderSample
    ) -> BenchCaseResult {
        BenchCaseResult(
            id: testCase.id, suite: testCase.suite, tags: testCase.tags,
            backend: testCase.backend, modelRow: testCase.modelRow, expected: testCase.expected,
            classification: classification, reason: reason, shown: shown,
            duplicateAfterCursor: duplicate, stalePublication: stale,
            providerCalled: sample.output != nil, latencyMs: sample.latencyMs,
            prefillBytes: sample.prefillBytes, prefillTokens: sample.prefillTokens, skipReason: nil,
            scheduling: schedulingMeasurement(testCase), reuse: reuseMeasurement(testCase),
            speculation: speculationMeasurement(testCase)
        )
    }

    private func schedulingMeasurement(_ testCase: BenchCase) -> BenchSchedulingMeasurement? {
        guard let fixture = testCase.scheduling else { return nil }
        let decision = SuggestionSchedulingPolicy().decision(.init(
            route: fixture.route,
            invocation: testCase.invocation,
            mutation: fixture.mutation,
            recentBackendLatencyMs: fixture.recentBackendLatencyMs,
            hostPublishElapsedMs: fixture.hostPublishElapsedMs,
            hostPublishOutcome: fixture.hostPublishOutcome,
            recentTypingIntervalMs: fixture.recentTypingIntervalMs
        ))
        let matches = decision.targetDebounceMs == fixture.expectedTargetDebounceMs
            && decision.remainingDebounceMs == fixture.expectedRemainingDebounceMs
            && decision.action == fixture.expectedAction
        return BenchSchedulingMeasurement(
            route: fixture.route,
            targetDebounceMs: decision.targetDebounceMs,
            remainingDebounceMs: decision.remainingDebounceMs,
            action: decision.action,
            reason: decision.reason,
            matchesExpectation: matches
        )
    }

    private func reuseMeasurement(_ testCase: BenchCase) -> BenchReuseMeasurement? {
        guard let fixture = testCase.reuse else { return nil }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let initial = makeContext(testCase, now: now, live: false)
        var store = SuggestionReuseStore(configuration: .init(ttl: 30))
        store.record(SuggestionCandidateSnapshot(
            context: initial,
            backend: fixture.route,
            candidates: fixture.candidates,
            createdAt: now
        ), now: now)
        if let observed = fixture.observedBeforeCursor {
            _ = store.decision(
                for: reuseContext(testCase, beforeCursor: observed, now: now),
                backend: fixture.route,
                mutation: .append,
                now: now
            )
        }
        let decision = store.decision(
            for: makeContext(testCase, now: now, live: true),
            backend: fixture.route,
            mutation: fixture.mutation,
            now: now
        )
        let action: BenchReuseExpectedAction
        let match: SuggestionReuseMatch?
        switch decision {
        case .promoteAppend(let value): action = .promoteAppend; match = value
        case .restoreRollback(let value): action = .restoreRollback; match = value
        case .mustRecompute, .notApplicable: action = .recompute; match = nil
        }
        let matches = action == fixture.expectedAction
            && match?.sourceRank == fixture.expectedRank
            && match?.remainingText.count == fixture.expectedRemainingCharacters
        return BenchReuseMeasurement(
            route: fixture.route,
            action: action,
            sourceRank: match?.sourceRank,
            remainingCharacters: match?.remainingText.count,
            providerCallSkipped: action != .recompute,
            matchesExpectation: matches
        )
    }

    private func reuseContext(_ testCase: BenchCase, beforeCursor: String, now: Date) -> TextContext {
        TextContext(
            app: AppIdentity(bundleID: testCase.appBundleID, displayName: testCase.appDisplayName, processID: 1),
            domain: testCase.domain,
            focusedElementID: "bench-field",
            textBeforeCursor: beforeCursor,
            textAfterCursor: testCase.afterCursor,
            selectedText: testCase.selectedText,
            caretRect: CGRect(x: 100, y: 100, width: 2, height: 20),
            focusedElementRect: CGRect(x: 20, y: 20, width: 800, height: 600),
            caretGeometryQuality: testCase.geometryQuality,
            createdAt: now
        )
    }

    private func speculationMeasurement(_ testCase: BenchCase) -> BenchSpeculationMeasurement? {
        guard let fixture = testCase.speculation else { return nil }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let context = makeContext(testCase, now: now, live: false)
        let decision = PostAcceptanceSpeculationPolicy(configuration: .init(enabled: true)).decision(
            context: context,
            insertedText: fixture.insertedText,
            route: fixture.route,
            inputMethodState: .asciiCompatible
        )
        let action: BenchSpeculationExpectedAction
        let signatureMatched: Bool
        switch decision {
        case .start(let speculative):
            action = .start
            signatureMatched = speculative.signature.matches(
                reuseContext(testCase, beforeCursor: fixture.publishedBeforeCursor, now: now)
            )
        case .ineligible:
            action = .ineligible
            signatureMatched = false
        }
        return BenchSpeculationMeasurement(
            route: fixture.route,
            action: action,
            signatureMatched: signatureMatched,
            matchesExpectation: action == fixture.expectedAction
                && signatureMatched == fixture.expectedSignatureMatch
        )
    }

    private func isAcceptable(_ actual: String, for testCase: BenchCase) -> Bool {
        let normalizedActual = unicode(actual, mode: testCase.unicodeNormalization)
        return testCase.acceptableContinuations.contains { candidate in
            let expected = unicode(candidate, mode: testCase.unicodeNormalization)
            switch testCase.tolerance {
            case .exact: return normalizedActual == expected
            case .prefix: return expected.hasPrefix(normalizedActual) || normalizedActual.hasPrefix(expected)
            }
        }
    }

    private func unicode(_ value: String, mode: BenchUnicodeNormalization) -> String {
        switch mode {
        case .none: return value
        case .nfc: return value.precomposedStringWithCanonicalMapping
        case .nfd: return value.decomposedStringWithCanonicalMapping
        }
    }

    private func isDuplicateAfterCursor(_ value: String, after: String?) -> Bool {
        guard let after, !after.isEmpty, !value.isEmpty else { return false }
        return value.hasSuffix(after) || after.hasPrefix(value)
    }

    private func guardrailReason(_ decision: SuggestionGuardrailValidator.Decision) -> String {
        switch decision {
        case .allowAccept: return "allow"
        case .blockAndHide(let reason), .blockAndRegenerate(let reason), .blockAndNoop(let reason): return reason.rawValue
        }
    }
}
