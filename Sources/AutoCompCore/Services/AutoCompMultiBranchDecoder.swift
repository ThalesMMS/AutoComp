import Foundation

public struct AutoCompScoredToken: Equatable, Sendable {
    public var tokenID: Int32
    public var logProbability: Float

    public init(tokenID: Int32, logProbability: Float) {
        self.tokenID = tokenID
        self.logProbability = logProbability
    }
}

public protocol AutoCompTokenScoringRuntime: Sendable {
    func topTokens(
        prompt: String,
        generatedTokenIDs: [Int32],
        allowedTokenIDs: [Int32]?,
        limit: Int
    ) async throws -> [AutoCompScoredToken]
}

public struct AutoCompMultiBranchDecodePolicy: Equatable, Sendable {
    public var maximumTokens: Int
    public var maximumDisplayWidth: Int
    public var frontierWidth: Int
    public var candidateCount: Int
    public var candidatePoolSize: Int
    public var minimumProbability: Float
    public var relativeProbabilityCutoff: Float
    public var stopSequences: [String]

    public init(
        maximumTokens: Int = 32,
        maximumDisplayWidth: Int = 160,
        frontierWidth: Int = 4,
        candidateCount: Int = 3,
        candidatePoolSize: Int = 32,
        minimumProbability: Float = 0.000_01,
        relativeProbabilityCutoff: Float = 0.02,
        stopSequences: [String] = []
    ) {
        self.maximumTokens = max(1, maximumTokens)
        self.maximumDisplayWidth = max(1, maximumDisplayWidth)
        self.frontierWidth = max(1, min(frontierWidth, 16))
        self.candidateCount = max(1, min(candidateCount, 16))
        self.candidatePoolSize = max(self.frontierWidth, min(candidatePoolSize, 4_096))
        self.minimumProbability = max(0, minimumProbability)
        self.relativeProbabilityCutoff = min(1, max(0, relativeProbabilityCutoff))
        self.stopSequences = stopSequences.filter { !$0.isEmpty }
    }
}

public struct AutoCompMultiBranchCandidate: Equatable, Sendable {
    public var tokenIDs: [Int32]
    public var text: String
    public var logProbability: Float

    public init(tokenIDs: [Int32], text: String, logProbability: Float) {
        self.tokenIDs = tokenIDs
        self.text = text
        self.logProbability = logProbability
    }
}

public struct AutoCompMultiBranchMetrics: Equatable, Sendable {
    public var profileLoadMilliseconds: Double = 0
    public var profileBytes: Int = 0
    public var branchesExpanded = 0
    public var branchesPruned = 0
    public var maximumDepth = 0
    public var scoredTokens = 0
    public var suppressedTokens = 0
    public var candidateCount = 0
    public var decodeMilliseconds: Double = 0
    public var cancellationCount = 0
    public var wrongShowCount = 0
    public var fallbackReason: AutoCompMultiBranchFallbackReason?

    public init() {}
}

public enum AutoCompMultiBranchFallbackReason: String, Equatable, Sendable {
    case featureDisabled = "feature-disabled"
    case profileMissing = "profile-missing"
    case profileInvalid = "profile-invalid"
    case tokenizerMismatch = "tokenizer-mismatch"
    case runtimeUnsupported = "runtime-unsupported"
    case decoderFailed = "decoder-failed"
    case candidatesRejected = "candidates-rejected"
}

public typealias AutoCompMultiBranchMetricsRecorder = @Sendable (AutoCompMultiBranchMetrics) async -> Void

public struct AutoCompMultiBranchDecodeResult: Equatable, Sendable {
    public var candidates: [AutoCompMultiBranchCandidate]
    public var metrics: AutoCompMultiBranchMetrics

    public init(candidates: [AutoCompMultiBranchCandidate], metrics: AutoCompMultiBranchMetrics) {
        self.candidates = candidates
        self.metrics = metrics
    }
}

public enum AutoCompMultiBranchDecodeError: LocalizedError, Equatable, Sendable {
    case emptyVocabulary
    case impossibleRequiredPrefix
    case noCandidate

    public var errorDescription: String? {
        switch self {
        case .emptyVocabulary: return "The token profile has no vocabulary."
        case .impossibleRequiredPrefix: return "No token path can satisfy the required prefix."
        case .noCandidate: return "The constrained decoder produced no candidate."
        }
    }
}

public struct AutoCompMultiBranchDecoder: Sendable {
    public init() {}

    public func decode(
        prompt: String,
        requiredPrefix: String = "",
        profile: AutoCompTokenProfile,
        policy: AutoCompMultiBranchDecodePolicy,
        runtime: any AutoCompTokenScoringRuntime
    ) async throws -> AutoCompMultiBranchDecodeResult {
        guard !profile.records.isEmpty else { throw AutoCompMultiBranchDecodeError.emptyVocabulary }
        let recordsByID = Dictionary(uniqueKeysWithValues: profile.records.map { ($0.id, $0) })
        let requiredBytes = Data(requiredPrefix.utf8)
        var frontier = [Branch()]
        var finished: [Branch] = []
        var metrics = AutoCompMultiBranchMetrics()

        for depth in 0..<policy.maximumTokens {
            try Task.checkCancellation()
            var expanded: [Branch] = []
            for branch in frontier {
                try Task.checkCancellation()
                let allowed = compatibleTokenIDs(
                    records: profile.records,
                    generatedBytes: branch.bytes,
                    requiredPrefix: requiredBytes
                )
                if !requiredBytes.isEmpty, !branch.bytes.starts(with: requiredBytes), allowed.isEmpty {
                    metrics.branchesPruned += 1
                    continue
                }
                let scores = try await runtime.topTokens(
                    prompt: prompt,
                    generatedTokenIDs: branch.tokenIDs,
                    allowedTokenIDs: allowed.isEmpty ? nil : allowed,
                    limit: policy.candidatePoolSize
                )
                try Task.checkCancellation()
                metrics.scoredTokens += scores.count
                guard let best = scores.first?.logProbability else { continue }

                for scored in scores {
                    guard scored.logProbability.isFinite,
                          let record = recordsByID[scored.tokenID] else {
                        metrics.suppressedTokens += 1
                        continue
                    }
                    let probability = exp(scored.logProbability)
                    let relative = exp(scored.logProbability - best)
                    guard probability >= policy.minimumProbability,
                          relative >= policy.relativeProbabilityCutoff,
                          !record.flags.contains(.control),
                          !record.flags.contains(.special),
                          !profile.specialTokenIDs.contains(record.id) else {
                        metrics.suppressedTokens += 1
                        continue
                    }

                    var next = branch
                    next.tokenIDs.append(record.id)
                    next.bytes.append(record.bytes)
                    next.displayWidth += Int(record.approximateDisplayWidth)
                    next.logProbability += scored.logProbability
                    next.tokenContributions.append(TokenContribution(
                        tokenID: record.id,
                        bytes: record.bytes,
                        displayWidth: Int(record.approximateDisplayWidth),
                        logProbability: scored.logProbability
                    ))
                    guard next.displayWidth <= policy.maximumDisplayWidth,
                          prefixIsCompatible(next.bytes, requiredPrefix: requiredBytes) else {
                        metrics.branchesPruned += 1
                        continue
                    }
                    metrics.branchesExpanded += 1
                    let isStopToken = record.flags.contains(.stop)
                        || record.flags.contains(.endOfGeneration)
                        || profile.stopTokenIDs.contains(record.id)
                    if isStopToken || containsStopSequence(next.bytes, stopSequences: policy.stopSequences) {
                        if let truncated = truncateAtStop(next, stopSequences: policy.stopSequences) {
                            finished.append(truncated)
                        }
                    } else {
                        expanded.append(next)
                    }
                }
            }
            metrics.maximumDepth = depth + 1
            let deduplicated = deduplicate(expanded)
            metrics.branchesPruned += max(0, expanded.count - min(deduplicated.count, policy.frontierWidth))
            frontier = Array(deduplicated.prefix(policy.frontierWidth))
            if frontier.isEmpty { break }
        }
        finished.append(contentsOf: frontier)

        let candidates = deduplicate(finished)
            .compactMap { branch -> AutoCompMultiBranchCandidate? in
                guard branch.bytes.starts(with: requiredBytes),
                      let text = String(data: branch.bytes, encoding: .utf8),
                      !text.isEmpty else { return nil }
                return AutoCompMultiBranchCandidate(
                    tokenIDs: branch.tokenIDs,
                    text: text,
                    logProbability: branch.logProbability
                )
            }
            .prefix(policy.candidateCount)
        guard !candidates.isEmpty else {
            if !requiredBytes.isEmpty { throw AutoCompMultiBranchDecodeError.impossibleRequiredPrefix }
            throw AutoCompMultiBranchDecodeError.noCandidate
        }
        metrics.candidateCount = candidates.count
        return AutoCompMultiBranchDecodeResult(candidates: Array(candidates), metrics: metrics)
    }

    private func compatibleTokenIDs(
        records: [AutoCompTokenRecord],
        generatedBytes: Data,
        requiredPrefix: Data
    ) -> [Int32] {
        guard !requiredPrefix.isEmpty, !generatedBytes.starts(with: requiredPrefix) else { return [] }
        return records.compactMap { record in
            guard !record.bytes.isEmpty,
                  !record.flags.contains(.control),
                  !record.flags.contains(.special),
                  !record.flags.contains(.stop),
                  !record.flags.contains(.endOfGeneration) else { return nil }
            var candidate = generatedBytes
            candidate.append(record.bytes)
            return prefixIsCompatible(candidate, requiredPrefix: requiredPrefix) ? record.id : nil
        }
    }

    private func prefixIsCompatible(_ bytes: Data, requiredPrefix: Data) -> Bool {
        requiredPrefix.isEmpty || requiredPrefix.starts(with: bytes) || bytes.starts(with: requiredPrefix)
    }

    private func containsStopSequence(_ bytes: Data, stopSequences: [String]) -> Bool {
        guard let text = String(data: bytes, encoding: .utf8) else { return false }
        return stopSequences.contains { text.contains($0) }
    }

    private func truncateAtStop(_ branch: Branch, stopSequences: [String]) -> Branch? {
        guard let text = String(data: branch.bytes, encoding: .utf8) else {
            return branch.bytes.isEmpty ? nil : branch
        }
        let offsets = stopSequences.compactMap { stop -> String.Index? in
            text.range(of: stop)?.lowerBound
        }
        guard let earliest = offsets.min() else {
            return branch.bytes.isEmpty ? nil : branch
        }
        let prefix = String(text[..<earliest])
        guard !prefix.isEmpty else { return nil }
        let prefixBytes = Data(prefix.utf8)
        var retainedContributions: [TokenContribution] = []
        var retainedByteCount = 0
        for contribution in branch.tokenContributions {
            let nextByteCount = retainedByteCount + contribution.bytes.count
            guard nextByteCount <= prefixBytes.count else { break }
            retainedContributions.append(contribution)
            retainedByteCount = nextByteCount
        }
        let retainedBytes = retainedContributions.reduce(into: Data()) { partial, contribution in
            partial.append(contribution.bytes)
        }
        guard !retainedBytes.isEmpty else { return nil }
        var truncated = branch
        truncated.tokenIDs = retainedContributions.map(\.tokenID)
        truncated.bytes = retainedBytes
        truncated.displayWidth = retainedContributions.reduce(0) { $0 + $1.displayWidth }
        truncated.logProbability = retainedContributions.reduce(0) { $0 + $1.logProbability }
        truncated.tokenContributions = retainedContributions
        return truncated
    }

    private func deduplicate(_ branches: [Branch]) -> [Branch] {
        var bestByBytes: [Data: Branch] = [:]
        for branch in branches {
            if let existing = bestByBytes[branch.bytes], ordered(existing, before: branch) {
                continue
            }
            bestByBytes[branch.bytes] = branch
        }
        return bestByBytes.values.sorted(by: ordered)
    }

    private func ordered(_ lhs: Branch, before rhs: Branch) -> Bool {
        if lhs.logProbability != rhs.logProbability { return lhs.logProbability > rhs.logProbability }
        return lhs.tokenIDs.lexicographicallyPrecedes(rhs.tokenIDs)
    }

    private struct Branch: Sendable {
        var tokenIDs: [Int32] = []
        var bytes = Data()
        var displayWidth = 0
        var logProbability: Float = 0
        var tokenContributions: [TokenContribution] = []
    }

    private struct TokenContribution: Sendable {
        let tokenID: Int32
        let bytes: Data
        let displayWidth: Int
        let logProbability: Float
    }
}
