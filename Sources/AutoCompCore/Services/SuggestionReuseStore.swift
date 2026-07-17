import Foundation

public enum SuggestionReuseMutation: String, Codable, Sendable {
    case append
    case delete
    case other
}

public enum SuggestionReuseMissReason: String, Sendable {
    case disabled
    case expired
    case backendChanged = "backend-changed"
    case appChanged = "app-changed"
    case domainChanged = "domain-changed"
    case fieldChanged = "field-changed"
    case suffixChanged = "suffix-changed"
    case selectionChanged = "selection-changed"
    case basePrefixChanged = "base-prefix-changed"
    case scriptChanged = "script-changed"
    case noCompatibleCandidate = "no-compatible-candidate"
    case rollbackTooLarge = "rollback-too-large"
    case remainderTooShort = "remainder-too-short"
}

public struct SuggestionReusableCandidate: Codable, Equatable, Sendable {
    public let text: String
    public let originalRank: Int
    public let score: Double?

    public init(text: String, originalRank: Int, score: Double? = nil) {
        self.text = text
        self.originalRank = max(0, originalRank)
        self.score = score
    }
}

public struct SuggestionCandidateSnapshot: Equatable, Sendable {
    public let id: UUID
    public let target: ActiveSuggestionTarget
    public let baseTextBeforeCursor: String
    public let backend: CompletionEngineKind
    public let candidates: [SuggestionReusableCandidate]
    public let createdAt: Date
    public let sequence: UInt64

    public init(
        id: UUID = UUID(),
        target: ActiveSuggestionTarget,
        baseTextBeforeCursor: String,
        backend: CompletionEngineKind,
        candidates: [SuggestionReusableCandidate],
        createdAt: Date = Date(),
        sequence: UInt64 = 0
    ) {
        self.id = id
        self.target = target
        self.baseTextBeforeCursor = baseTextBeforeCursor
        self.backend = backend
        self.candidates = candidates
        self.createdAt = createdAt
        self.sequence = sequence
    }

    public init(
        context: TextContext,
        backend: CompletionEngineKind,
        candidates: [SuggestionReusableCandidate],
        createdAt: Date = Date(),
        sequence: UInt64 = 0
    ) {
        self.init(
            target: ActiveSuggestionTarget(context: context),
            baseTextBeforeCursor: context.textBeforeCursor,
            backend: backend,
            candidates: candidates,
            createdAt: createdAt,
            sequence: sequence
        )
    }
}

public struct SuggestionReuseMatch: Equatable, Sendable {
    public let snapshotID: UUID
    public let remainingText: String
    public let sourceRank: Int
    public let snapshotAgeMs: Int
    public let consumedCharacterCount: Int
}

public enum SuggestionReuseDecision: Equatable, Sendable {
    case promoteAppend(SuggestionReuseMatch)
    case restoreRollback(SuggestionReuseMatch)
    case notApplicable
    case mustRecompute(reason: SuggestionReuseMissReason)
}

public struct SuggestionReuseStore: Sendable {
    public struct Configuration: Equatable, Sendable {
        public var enabled: Bool
        public var maximumSnapshots: Int
        public var maximumCandidates: Int
        public var ttl: TimeInterval
        public var minimumRemainingCharacters: Int
        public var maximumRollbackCharacters: Int

        public init(
            enabled: Bool = true,
            maximumSnapshots: Int = 6,
            maximumCandidates: Int = 18,
            ttl: TimeInterval = 20,
            minimumRemainingCharacters: Int = 2,
            maximumRollbackCharacters: Int = 3
        ) {
            self.enabled = enabled
            self.maximumSnapshots = max(1, maximumSnapshots)
            self.maximumCandidates = max(1, maximumCandidates)
            self.ttl = max(0, ttl)
            self.minimumRemainingCharacters = max(1, minimumRemainingCharacters)
            self.maximumRollbackCharacters = max(1, maximumRollbackCharacters)
        }

        public static func environmentDefault(environment: [String: String] = ProcessInfo.processInfo.environment) -> Configuration {
            var configuration = Configuration()
            let disabled = environment["AUTOCOMP_DISABLE_SUGGESTION_REUSE"]?.lowercased()
            configuration.enabled = !["1", "true", "yes", "on"].contains(disabled ?? "")
            return configuration
        }
    }

    public let configuration: Configuration
    public private(set) var evictionCount = 0
    private var snapshots: [SuggestionCandidateSnapshot] = []
    private var furthestObservedCount: [UUID: Int] = [:]
    private var nextSequence: UInt64 = 0

    public init(configuration: Configuration = .environmentDefault()) {
        self.configuration = configuration
    }

    public var snapshotCount: Int { snapshots.count }
    public var candidateCount: Int { snapshots.reduce(0) { $0 + $1.candidates.count } }

    public mutating func record(_ snapshot: SuggestionCandidateSnapshot, now: Date = Date()) {
        guard configuration.enabled else { return }
        pruneExpired(now: now)
        let unique = deduplicated(snapshot.candidates)
        guard !unique.isEmpty else { return }
        nextSequence &+= 1
        let bounded = Array(unique.prefix(configuration.maximumCandidates))
        let recorded = SuggestionCandidateSnapshot(
            id: snapshot.id,
            target: snapshot.target,
            baseTextBeforeCursor: snapshot.baseTextBeforeCursor,
            backend: snapshot.backend,
            candidates: bounded,
            createdAt: snapshot.createdAt,
            sequence: nextSequence
        )
        let supersededIDs = snapshots.compactMap { existing in
            existing.target == recorded.target && existing.backend == recorded.backend
                ? existing.id
                : nil
        }
        snapshots.removeAll { supersededIDs.contains($0.id) }
        for id in supersededIDs {
            furthestObservedCount[id] = nil
        }
        snapshots.append(recorded)
        furthestObservedCount[recorded.id] = 0
        enforceBounds()
    }

    public mutating func decision(
        for context: TextContext,
        backend: CompletionEngineKind,
        mutation: SuggestionReuseMutation,
        now: Date = Date()
    ) -> SuggestionReuseDecision {
        guard configuration.enabled else { return .mustRecompute(reason: .disabled) }
        let expired = pruneExpired(now: now)
        guard !snapshots.isEmpty else {
            return expired > 0 ? .mustRecompute(reason: .expired) : .notApplicable
        }
        guard mutation != .other else { return .notApplicable }

        var firstMiss: SuggestionReuseMissReason?
        for snapshot in snapshots.sorted(by: { $0.sequence > $1.sequence }) {
            if let reason = targetMiss(snapshot, context: context, backend: backend) {
                firstMiss = firstMiss ?? reason
                continue
            }
            guard context.textBeforeCursor.hasPrefix(snapshot.baseTextBeforeCursor) else {
                firstMiss = firstMiss ?? .basePrefixChanged
                continue
            }

            let typed = String(context.textBeforeCursor.dropFirst(snapshot.baseTextBeforeCursor.count))
            if typed.isEmpty, mutation == .append { return .notApplicable }
            let compatible = snapshot.candidates
                .filter { $0.text.hasPrefix(typed) }
                .sorted { $0.originalRank < $1.originalRank }
            guard let candidate = compatible.first else {
                furthestObservedCount[snapshot.id] = max(
                    furthestObservedCount[snapshot.id, default: 0],
                    typed.count
                )
                firstMiss = firstMiss ?? (scriptChanged(typed, candidates: snapshot.candidates)
                    ? .scriptChanged
                    : .noCompatibleCandidate)
                continue
            }

            let remaining = String(candidate.text.dropFirst(typed.count))
            guard remaining.count >= configuration.minimumRemainingCharacters else {
                firstMiss = firstMiss ?? .remainderTooShort
                continue
            }
            if mutation == .delete {
                let furthest = furthestObservedCount[snapshot.id, default: typed.count]
                let rollback = max(0, furthest - typed.count)
                guard rollback > 0, rollback <= configuration.maximumRollbackCharacters else {
                    firstMiss = firstMiss ?? .rollbackTooLarge
                    continue
                }
            } else {
                furthestObservedCount[snapshot.id] = max(
                    furthestObservedCount[snapshot.id, default: 0],
                    typed.count
                )
            }

            let match = SuggestionReuseMatch(
                snapshotID: snapshot.id,
                remainingText: remaining,
                sourceRank: candidate.originalRank,
                snapshotAgeMs: max(0, Int(now.timeIntervalSince(snapshot.createdAt) * 1_000)),
                consumedCharacterCount: typed.count
            )
            return mutation == .delete ? .restoreRollback(match) : .promoteAppend(match)
        }
        return .mustRecompute(reason: firstMiss ?? .noCompatibleCandidate)
    }

    public mutating func reset() {
        snapshots.removeAll(keepingCapacity: true)
        furthestObservedCount.removeAll(keepingCapacity: true)
    }

    @discardableResult
    private mutating func pruneExpired(now: Date) -> Int {
        let expiredIDs = Set(snapshots.filter {
            now.timeIntervalSince($0.createdAt) > configuration.ttl
        }.map(\.id))
        guard !expiredIDs.isEmpty else { return 0 }
        snapshots.removeAll { expiredIDs.contains($0.id) }
        for id in expiredIDs { furthestObservedCount[id] = nil }
        evictionCount += expiredIDs.count
        return expiredIDs.count
    }

    private mutating func enforceBounds() {
        while snapshots.count > configuration.maximumSnapshots
                || candidateCount > configuration.maximumCandidates {
            guard let oldest = snapshots.min(by: { $0.sequence < $1.sequence }) else { break }
            snapshots.removeAll { $0.id == oldest.id }
            furthestObservedCount[oldest.id] = nil
            evictionCount += 1
        }
    }

    private func deduplicated(_ candidates: [SuggestionReusableCandidate]) -> [SuggestionReusableCandidate] {
        var seen: Set<String> = []
        return candidates.filter {
            !$0.text.isEmpty && seen.insert($0.text).inserted
        }.sorted { $0.originalRank < $1.originalRank }
    }

    private func targetMiss(
        _ snapshot: SuggestionCandidateSnapshot,
        context: TextContext,
        backend: CompletionEngineKind
    ) -> SuggestionReuseMissReason? {
        guard snapshot.backend == backend else { return .backendChanged }
        guard snapshot.target.app == context.app else { return .appChanged }
        guard snapshot.target.domain == context.domain else { return .domainChanged }
        let fieldMatches: Bool
        if let baseline = snapshot.target.stableFieldIdentity,
           let current = context.stableFieldIdentity {
            fieldMatches = baseline.matchesStableTarget(current)
        } else {
            fieldMatches = snapshot.target.focusedElementID == context.focusedElementID
        }
        guard fieldMatches else { return .fieldChanged }
        guard (snapshot.target.textAfterCursor ?? "") == (context.textAfterCursor ?? "") else {
            return .suffixChanged
        }
        guard snapshot.target.selectedRange == context.selectedRange,
              snapshot.target.selectedText == context.selectedText else {
            return .selectionChanged
        }
        return nil
    }

    private func scriptChanged(
        _ typed: String,
        candidates: [SuggestionReusableCandidate]
    ) -> Bool {
        guard let typedFamily = scriptFamily(typed),
              let candidateFamily = candidates.compactMap({ scriptFamily($0.text) }).first else {
            return false
        }
        return typedFamily != candidateFamily
    }

    private func scriptFamily(_ text: String) -> Int? {
        for scalar in text.unicodeScalars where CharacterSet.letters.contains(scalar) {
            switch scalar.value {
            case 0x0041...0x024F: return 1 // Latin
            case 0x0400...0x052F: return 2 // Cyrillic
            case 0x0600...0x06FF: return 3 // Arabic
            case 0x3040...0x30FF, 0x3400...0x9FFF: return 4 // Japanese/CJK
            default: return 5
            }
        }
        return nil
    }
}
