import Foundation

/// Centralized validator for determining whether it is safe to accept a stored suggestion given the
/// current focus/context snapshot.
///
/// This is privacy-safe by design: it compares stable element identities and hashed fingerprints
/// rather than raw user text.
public struct SuggestionGuardrailValidator: Sendable {
    public enum Decision: Sendable, Equatable {
        case allowAccept
        case blockAndHide(reason: Reason)
        case blockAndRegenerate(reason: Reason)
        case blockAndNoop(reason: Reason)
    }

    public enum Reason: String, Sendable, Codable {
        case missingBinding
        case stale
        case focusedElementMismatch
        case fieldIdentityMismatch
        case contextDrift
    }

    public struct Policy: Sendable {
        public var freshnessWindow: TimeInterval
        public var maxPrefixLengthDelta: Int
        public var maxSuffixLengthDelta: Int

        /// If true, an element identity mismatch triggers regeneration; otherwise it just hides.
        public var regenerateOnFocusedElementMismatch: Bool

        /// If true, context drift triggers regeneration; otherwise it hides.
        public var regenerateOnContextDrift: Bool

        public init(
            freshnessWindow: TimeInterval = SuggestionBinding.defaultFreshnessWindow,
            maxPrefixLengthDelta: Int = 2,
            maxSuffixLengthDelta: Int = 2,
            regenerateOnFocusedElementMismatch: Bool = true,
            regenerateOnContextDrift: Bool = true
        ) {
            self.freshnessWindow = freshnessWindow
            self.maxPrefixLengthDelta = maxPrefixLengthDelta
            self.maxSuffixLengthDelta = maxSuffixLengthDelta
            self.regenerateOnFocusedElementMismatch = regenerateOnFocusedElementMismatch
            self.regenerateOnContextDrift = regenerateOnContextDrift
        }
    }

    public static let `default` = SuggestionGuardrailValidator()

    private let policy: Policy

    public init(policy: Policy = Policy()) {
        self.policy = policy
    }

    /// Validate a suggestion binding against current snapshot data.
    /// - Parameters:
    ///   - binding: Stored suggestion binding.
    ///   - currentStableFieldIdentity: Current focused field identity.
    ///   - currentFocusedElementID: Current focused element identifier.
    ///   - currentContextFingerprint: Fingerprint of current text context.
    ///   - now: Injectable clock for tests.
    public func validateAccept(
        binding: SuggestionBinding?,
        currentStableFieldIdentity: StableFieldIdentity?,
        currentFocusedElementID: String?,
        currentContextFingerprint: SuggestionContextFingerprint?,
        now: Date = Date()
    ) -> Decision {
        guard let binding else {
            return .blockAndHide(reason: .missingBinding)
        }

        if binding.isStale(now: now, freshnessWindow: policy.freshnessWindow) {
            return .blockAndRegenerate(reason: .stale)
        }

        let stableFieldMatches: Bool = {
            guard let baselineFieldIdentity = binding.stableFieldIdentity,
                  let currentStableFieldIdentity else {
                return false
            }
            return baselineFieldIdentity.matchesStableTarget(currentStableFieldIdentity)
        }()
        let googleDocsTextContextMatches = isGoogleDocsTextFingerprintMatch(
            binding.contextFingerprint,
            currentContextFingerprint
        )
            && isSameGoogleDocsStableTarget(
                binding.stableFieldIdentity,
                currentStableFieldIdentity
            )
        let targetMatches = stableFieldMatches || googleDocsTextContextMatches

        if let baselineElementID = binding.focusedElementID,
           let currentFocusedElementID,
           baselineElementID != currentFocusedElementID,
           !targetMatches {
            return policy.regenerateOnFocusedElementMismatch
                ? .blockAndRegenerate(reason: .focusedElementMismatch)
                : .blockAndHide(reason: .focusedElementMismatch)
        }

        if binding.stableFieldIdentity != nil,
           currentStableFieldIdentity != nil,
           !targetMatches {
            return .blockAndHide(reason: .fieldIdentityMismatch)
        }

        if let baselineFingerprint = binding.contextFingerprint,
           let currentContextFingerprint {
            let ok = SuggestionContextFingerprint.isSafeMatch(
                baseline: baselineFingerprint,
                current: currentContextFingerprint,
                maxPrefixLengthDelta: policy.maxPrefixLengthDelta,
                maxSuffixLengthDelta: policy.maxSuffixLengthDelta
            )
            if !ok && !googleDocsTextContextMatches {
                return policy.regenerateOnContextDrift
                    ? .blockAndRegenerate(reason: .contextDrift)
                    : .blockAndHide(reason: .contextDrift)
            }
        }

        return .allowAccept
    }

    private func isSameGoogleDocsStableTarget(
        _ baseline: StableFieldIdentity?,
        _ current: StableFieldIdentity?
    ) -> Bool {
        guard let knownIdentity = baseline ?? current,
              knownIdentity.bundleID == "com.google.Chrome" else {
            return false
        }

        guard let baseline, let current else {
            return true
        }

        guard current.bundleID == baseline.bundleID,
              current.processID == baseline.processID else {
            return false
        }

        return true
    }

    private func hasGoogleDocsDomain(_ value: String?) -> Bool {
        value?.contains("docs.google.com") == true
    }

    private func isGoogleDocsTextFingerprintMatch(
        _ baseline: SuggestionContextFingerprint?,
        _ current: SuggestionContextFingerprint?
    ) -> Bool {
        guard let baseline,
              let current,
              hasGoogleDocsDomain(baseline.domain) || hasGoogleDocsDomain(current.domain),
              compatible(baseline.domain, current.domain),
              googleDocsCollapsedSelectionCompatible(baseline.selectedRange, current.selectedRange),
              baseline.prefixHash == current.prefixHash,
              baseline.suffixHash == current.suffixHash else {
            return false
        }

        if abs(baseline.prefixLength - current.prefixLength) > policy.maxPrefixLengthDelta {
            return false
        }
        if abs(baseline.suffixLength - current.suffixLength) > policy.maxSuffixLengthDelta {
            return false
        }

        return true
    }

    private func compatible(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else {
            return true
        }
        return lhs == rhs
    }

    private func googleDocsCollapsedSelectionCompatible(_ lhs: NSRange?, _ rhs: NSRange?) -> Bool {
        (lhs?.length ?? 0) == 0 && (rhs?.length ?? 0) == 0
    }
}
