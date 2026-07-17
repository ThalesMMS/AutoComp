import AutoCompCore
import Foundation

public enum BenchExpectedDecision: String, Codable, Sendable { case show, suppress }
public enum BenchTolerance: String, Codable, Sendable { case exact, prefix }
public enum BenchUnicodeNormalization: String, Codable, Sendable { case none, nfc, nfd }
public enum BenchNormalizationMode: String, Codable, Sendable { case production, identity }

public enum BenchReuseExpectedAction: String, Codable, Sendable {
    case promoteAppend = "promote-append"
    case restoreRollback = "restore-rollback"
    case recompute
}

public struct BenchReuseFixture: Codable, Equatable, Sendable {
    public let route: CompletionEngineKind
    public let mutation: SuggestionReuseMutation
    public let candidates: [SuggestionReusableCandidate]
    public let expectedAction: BenchReuseExpectedAction
    public let expectedRank: Int?
    public let expectedRemainingCharacters: Int?
    public let observedBeforeCursor: String?

    public init(
        route: CompletionEngineKind,
        mutation: SuggestionReuseMutation,
        candidates: [SuggestionReusableCandidate],
        expectedAction: BenchReuseExpectedAction,
        expectedRank: Int? = nil,
        expectedRemainingCharacters: Int? = nil,
        observedBeforeCursor: String? = nil
    ) {
        self.route = route; self.mutation = mutation; self.candidates = candidates
        self.expectedAction = expectedAction; self.expectedRank = expectedRank
        self.expectedRemainingCharacters = expectedRemainingCharacters
        self.observedBeforeCursor = observedBeforeCursor
    }
}

public enum BenchSpeculationExpectedAction: String, Codable, Sendable {
    case start
    case ineligible
}

public struct BenchSpeculationFixture: Codable, Equatable, Sendable {
    public let route: CompletionEngineKind
    public let insertedText: String
    public let publishedBeforeCursor: String
    public let expectedAction: BenchSpeculationExpectedAction
    public let expectedSignatureMatch: Bool

    public init(
        route: CompletionEngineKind,
        insertedText: String,
        publishedBeforeCursor: String,
        expectedAction: BenchSpeculationExpectedAction,
        expectedSignatureMatch: Bool
    ) {
        self.route = route; self.insertedText = insertedText
        self.publishedBeforeCursor = publishedBeforeCursor
        self.expectedAction = expectedAction; self.expectedSignatureMatch = expectedSignatureMatch
    }
}

public struct BenchSchedulingFixture: Codable, Equatable, Sendable {
    public let route: CompletionEngineKind
    public let mutation: SuggestionSchedulingMutation
    public let hostPublishElapsedMs: Int
    public let hostPublishOutcome: SuggestionSchedulingHostPublishOutcome
    public let recentBackendLatencyMs: Int?
    public let recentTypingIntervalMs: Int?
    public let expectedTargetDebounceMs: Int
    public let expectedRemainingDebounceMs: Int
    public let expectedAction: SuggestionSchedulingAction

    public init(
        route: CompletionEngineKind,
        mutation: SuggestionSchedulingMutation,
        hostPublishElapsedMs: Int,
        hostPublishOutcome: SuggestionSchedulingHostPublishOutcome,
        recentBackendLatencyMs: Int? = nil,
        recentTypingIntervalMs: Int? = nil,
        expectedTargetDebounceMs: Int,
        expectedRemainingDebounceMs: Int,
        expectedAction: SuggestionSchedulingAction
    ) {
        self.route = route; self.mutation = mutation
        self.hostPublishElapsedMs = hostPublishElapsedMs; self.hostPublishOutcome = hostPublishOutcome
        self.recentBackendLatencyMs = recentBackendLatencyMs
        self.recentTypingIntervalMs = recentTypingIntervalMs
        self.expectedTargetDebounceMs = expectedTargetDebounceMs
        self.expectedRemainingDebounceMs = expectedRemainingDebounceMs
        self.expectedAction = expectedAction
    }
}

public struct BenchConfiguration: Codable, Equatable, Sendable {
    public let id: String
    public let normalization: BenchNormalizationMode
    public let enforceLiveGuardrails: Bool

    public init(id: String, normalization: BenchNormalizationMode = .production, enforceLiveGuardrails: Bool = true) {
        self.id = id
        self.normalization = normalization
        self.enforceLiveGuardrails = enforceLiveGuardrails
    }

    public static let production = BenchConfiguration(id: "production")
}

public struct BenchCase: Codable, Equatable, Sendable {
    public let id: String
    public let suite: String
    public let synthetic: Bool
    public let beforeCursor: String
    public let afterCursor: String?
    public let selectedText: String?
    public let appBundleID: String
    public let appDisplayName: String
    public let domain: String?
    public let invocation: SuggestionEligibilityInvocation
    public let geometryQuality: CaretGeometryQuality
    public let caretAvailable: Bool
    public let backend: String
    public let modelRow: String
    public let fixtureOutput: String?
    public let fixtureOutputs: [String: String]
    public let expected: BenchExpectedDecision
    public let acceptableContinuations: [String]
    public let forbiddenPatterns: [String]
    public let tags: [String]
    public let tolerance: BenchTolerance
    public let unicodeNormalization: BenchUnicodeNormalization
    public let liveBeforeCursor: String?
    public let liveAfterCursor: String?
    public let suggestionAgeMs: Int
    public let providerLatencyMs: Int
    public let prefillBytes: Int
    public let prefillTokens: Int
    public let scheduling: BenchSchedulingFixture?
    public let reuse: BenchReuseFixture?
    public let speculation: BenchSpeculationFixture?

    public init(
        id: String,
        suite: String = "smoke",
        synthetic: Bool = true,
        beforeCursor: String,
        afterCursor: String? = nil,
        selectedText: String? = nil,
        appBundleID: String = "com.apple.TextEdit",
        appDisplayName: String = "TextEdit",
        domain: String? = nil,
        invocation: SuggestionEligibilityInvocation = .manual,
        geometryQuality: CaretGeometryQuality = .directCaret,
        caretAvailable: Bool = true,
        backend: String = "fixture",
        modelRow: String = "fixture-v1",
        fixtureOutput: String? = nil,
        fixtureOutputs: [String: String] = [:],
        expected: BenchExpectedDecision,
        acceptableContinuations: [String] = [],
        forbiddenPatterns: [String] = [],
        tags: [String],
        tolerance: BenchTolerance = .exact,
        unicodeNormalization: BenchUnicodeNormalization = .nfc,
        liveBeforeCursor: String? = nil,
        liveAfterCursor: String? = nil,
        suggestionAgeMs: Int = 0,
        providerLatencyMs: Int = 1,
        prefillBytes: Int = 0,
        prefillTokens: Int = 0,
        scheduling: BenchSchedulingFixture? = nil,
        reuse: BenchReuseFixture? = nil,
        speculation: BenchSpeculationFixture? = nil
    ) {
        self.id = id; self.suite = suite; self.synthetic = synthetic
        self.beforeCursor = beforeCursor; self.afterCursor = afterCursor; self.selectedText = selectedText
        self.appBundleID = appBundleID; self.appDisplayName = appDisplayName; self.domain = domain
        self.invocation = invocation; self.geometryQuality = geometryQuality; self.caretAvailable = caretAvailable
        self.backend = backend; self.modelRow = modelRow; self.fixtureOutput = fixtureOutput
        self.fixtureOutputs = fixtureOutputs; self.expected = expected
        self.acceptableContinuations = acceptableContinuations; self.forbiddenPatterns = forbiddenPatterns
        self.tags = tags; self.tolerance = tolerance; self.unicodeNormalization = unicodeNormalization
        self.liveBeforeCursor = liveBeforeCursor; self.liveAfterCursor = liveAfterCursor
        self.suggestionAgeMs = suggestionAgeMs; self.providerLatencyMs = providerLatencyMs
        self.prefillBytes = prefillBytes; self.prefillTokens = prefillTokens
        self.scheduling = scheduling
        self.reuse = reuse
        self.speculation = speculation
    }

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case id, suite, synthetic, beforeCursor, afterCursor, selectedText, appBundleID, appDisplayName, domain
        case invocation, geometryQuality, caretAvailable, backend, modelRow, fixtureOutput, fixtureOutputs
        case expected, acceptableContinuations, forbiddenPatterns, tags, tolerance, unicodeNormalization
        case liveBeforeCursor, liveAfterCursor, suggestionAgeMs, providerLatencyMs, prefillBytes, prefillTokens, scheduling, reuse, speculation
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            suite: try c.decodeIfPresent(String.self, forKey: .suite) ?? "smoke",
            synthetic: try c.decodeIfPresent(Bool.self, forKey: .synthetic) ?? true,
            beforeCursor: try c.decode(String.self, forKey: .beforeCursor),
            afterCursor: try c.decodeIfPresent(String.self, forKey: .afterCursor),
            selectedText: try c.decodeIfPresent(String.self, forKey: .selectedText),
            appBundleID: try c.decodeIfPresent(String.self, forKey: .appBundleID) ?? "com.apple.TextEdit",
            appDisplayName: try c.decodeIfPresent(String.self, forKey: .appDisplayName) ?? "TextEdit",
            domain: try c.decodeIfPresent(String.self, forKey: .domain),
            invocation: try c.decodeIfPresent(SuggestionEligibilityInvocation.self, forKey: .invocation) ?? .manual,
            geometryQuality: try c.decodeIfPresent(CaretGeometryQuality.self, forKey: .geometryQuality) ?? .directCaret,
            caretAvailable: try c.decodeIfPresent(Bool.self, forKey: .caretAvailable) ?? true,
            backend: try c.decodeIfPresent(String.self, forKey: .backend) ?? "fixture",
            modelRow: try c.decodeIfPresent(String.self, forKey: .modelRow) ?? "fixture-v1",
            fixtureOutput: try c.decodeIfPresent(String.self, forKey: .fixtureOutput),
            fixtureOutputs: try c.decodeIfPresent([String: String].self, forKey: .fixtureOutputs) ?? [:],
            expected: try c.decode(BenchExpectedDecision.self, forKey: .expected),
            acceptableContinuations: try c.decodeIfPresent([String].self, forKey: .acceptableContinuations) ?? [],
            forbiddenPatterns: try c.decodeIfPresent([String].self, forKey: .forbiddenPatterns) ?? [],
            tags: try c.decodeIfPresent([String].self, forKey: .tags) ?? [],
            tolerance: try c.decodeIfPresent(BenchTolerance.self, forKey: .tolerance) ?? .exact,
            unicodeNormalization: try c.decodeIfPresent(BenchUnicodeNormalization.self, forKey: .unicodeNormalization) ?? .nfc,
            liveBeforeCursor: try c.decodeIfPresent(String.self, forKey: .liveBeforeCursor),
            liveAfterCursor: try c.decodeIfPresent(String.self, forKey: .liveAfterCursor),
            suggestionAgeMs: try c.decodeIfPresent(Int.self, forKey: .suggestionAgeMs) ?? 0,
            providerLatencyMs: try c.decodeIfPresent(Int.self, forKey: .providerLatencyMs) ?? 1,
            prefillBytes: try c.decodeIfPresent(Int.self, forKey: .prefillBytes) ?? 0,
            prefillTokens: try c.decodeIfPresent(Int.self, forKey: .prefillTokens) ?? 0,
            scheduling: try c.decodeIfPresent(BenchSchedulingFixture.self, forKey: .scheduling),
            reuse: try c.decodeIfPresent(BenchReuseFixture.self, forKey: .reuse),
            speculation: try c.decodeIfPresent(BenchSpeculationFixture.self, forKey: .speculation)
        )
    }

    public func reporting(backend: String, modelRow: String) -> BenchCase {
        BenchCase(
            id: id, suite: suite, synthetic: synthetic, beforeCursor: beforeCursor,
            afterCursor: afterCursor, selectedText: selectedText, appBundleID: appBundleID,
            appDisplayName: appDisplayName, domain: domain, invocation: invocation,
            geometryQuality: geometryQuality, caretAvailable: caretAvailable,
            backend: backend, modelRow: modelRow, fixtureOutput: fixtureOutput,
            fixtureOutputs: fixtureOutputs, expected: expected,
            acceptableContinuations: acceptableContinuations, forbiddenPatterns: forbiddenPatterns,
            tags: tags, tolerance: tolerance, unicodeNormalization: unicodeNormalization,
            liveBeforeCursor: liveBeforeCursor, liveAfterCursor: liveAfterCursor,
            suggestionAgeMs: suggestionAgeMs, providerLatencyMs: providerLatencyMs,
            prefillBytes: prefillBytes, prefillTokens: prefillTokens, scheduling: scheduling,
            reuse: reuse, speculation: speculation
        )
    }
}

public enum BenchSkipReason: String, Codable, Equatable, Sendable {
    case localRuntimeUnavailable = "local-runtime-unavailable"
    case remoteConsentRequired = "remote-consent-required"
    case missingFixtureOutput = "missing-fixture-output"
    case providerFailure = "provider-failure"
}

public struct BenchProviderSample: Equatable, Sendable {
    public let output: String?
    public let latencyMs: Int
    public let prefillBytes: Int
    public let prefillTokens: Int
    public let skipReason: BenchSkipReason?

    public init(output: String, latencyMs: Int, prefillBytes: Int = 0, prefillTokens: Int = 0) {
        self.output = output; self.latencyMs = latencyMs; self.prefillBytes = prefillBytes
        self.prefillTokens = prefillTokens; self.skipReason = nil
    }

    public init(skip reason: BenchSkipReason) {
        output = nil; latencyMs = 0; prefillBytes = 0; prefillTokens = 0; skipReason = reason
    }
}

public protocol BenchCompletionProvider: Sendable {
    func sample(for testCase: BenchCase, configuration: BenchConfiguration) async -> BenchProviderSample
}

public struct FixtureBenchProvider: BenchCompletionProvider {
    public init() {}
    public func sample(for testCase: BenchCase, configuration: BenchConfiguration) async -> BenchProviderSample {
        guard let output = testCase.fixtureOutputs[configuration.id] ?? testCase.fixtureOutput else {
            return BenchProviderSample(skip: .missingFixtureOutput)
        }
        return BenchProviderSample(
            output: output,
            latencyMs: testCase.providerLatencyMs,
            prefillBytes: testCase.prefillBytes,
            prefillTokens: testCase.prefillTokens
        )
    }
}

public struct SkippingBenchProvider: BenchCompletionProvider {
    public let reason: BenchSkipReason
    public init(reason: BenchSkipReason) { self.reason = reason }
    public func sample(for testCase: BenchCase, configuration: BenchConfiguration) async -> BenchProviderSample {
        BenchProviderSample(skip: reason)
    }
}
