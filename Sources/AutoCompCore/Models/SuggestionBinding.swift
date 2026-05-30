import CoreGraphics
import Foundation

extension SuggestionContextFingerprint {
    /// Build a privacy-safe fingerprint from a `TextContext`.
    ///
    /// The fingerprint is intended for *equality-ish* checks at accept time and avoids storing raw
    /// user text. It includes:
    /// - Prefix/suffix lengths and stable hashes
    /// - Selection range (if any)
    /// - Domain (already normalized upstream)
    public static func from(textContext: TextContext) -> SuggestionContextFingerprint {
        let prefix = textContext.textBeforeCursor
        let suffix = textContext.textAfterCursor ?? ""

        return SuggestionContextFingerprint(
            prefixHash: Self.fnv1a64(prefix),
            prefixLength: prefix.count,
            suffixHash: Self.fnv1a64(suffix),
            suffixLength: suffix.count,
            selectedRange: textContext.selectedRange,
            domain: textContext.domain
        )
    }

    /// Returns true if `current` is close enough to the `baseline` fingerprint to treat acceptance as safe.
    ///
    /// Policy:
    /// - Domain mismatch => drift
    /// - Selection range mismatch (including collapsed vs non-collapsed) => drift
    /// - Prefix/suffix hashes must match (exact) and lengths must be within small tolerances
    public static func isSafeMatch(
        baseline: SuggestionContextFingerprint,
        current: SuggestionContextFingerprint,
        maxPrefixLengthDelta: Int,
        maxSuffixLengthDelta: Int
    ) -> Bool {
        if let baselineDomain = baseline.domain,
           let currentDomain = current.domain,
           baselineDomain != currentDomain {
            return false
        }

        if baseline.selectedRange?.location != current.selectedRange?.location {
            return false
        }
        if baseline.selectedRange?.length != current.selectedRange?.length {
            return false
        }

        if baseline.prefixHash != current.prefixHash {
            return false
        }
        if baseline.suffixHash != current.suffixHash {
            return false
        }

        if abs(baseline.prefixLength - current.prefixLength) > maxPrefixLengthDelta {
            return false
        }
        if abs(baseline.suffixLength - current.suffixLength) > maxSuffixLengthDelta {
            return false
        }

        return true
    }

    /// Tiny stable hash suitable for privacy-safe comparisons (not cryptographic).
    private static func fnv1a64(_ string: String) -> UInt64 {
        var hash: UInt64 = 0xcbf29ce484222325
        let prime: UInt64 = 0x100000001b3

        for byte in string.utf8 {
            hash ^= UInt64(byte)
            hash &*= prime
        }

        return hash
    }
}


/// In-memory metadata that binds a suggestion to the specific field/context it was generated for.
///
/// This is used by guardrails to prevent wrong-field insertion or acceptance after excessive drift.
///
/// Note: This should remain lightweight and privacy-safe. It intentionally avoids storing any raw
/// user text, and should not be persisted.
public struct SuggestionBinding: Equatable, Sendable {
    /// Default time window where accepting a suggestion is considered safe.
    ///
    /// This is intentionally conservative: AX focus and caret reporting can drift quickly across
    /// apps, and we prefer forcing regeneration over risking wrong-field insertion.
    public static let defaultFreshnessWindow: TimeInterval = 12

    public let stableFieldIdentity: StableFieldIdentity?
    public let focusedElementID: String?
    public let contextFingerprint: SuggestionContextFingerprint?
    public let caretSnapshot: SuggestionCaretSnapshot?
    public let generatedAt: Date

    public init(
        stableFieldIdentity: StableFieldIdentity?,
        focusedElementID: String?,
        contextFingerprint: SuggestionContextFingerprint?,
        caretSnapshot: SuggestionCaretSnapshot?,
        generatedAt: Date
    ) {
        self.stableFieldIdentity = stableFieldIdentity
        self.focusedElementID = focusedElementID
        self.contextFingerprint = contextFingerprint
        self.caretSnapshot = caretSnapshot
        self.generatedAt = generatedAt
    }

    /// Returns true if this binding is older than the provided window.
    public func isStale(now: Date = Date(), freshnessWindow: TimeInterval = Self.defaultFreshnessWindow) -> Bool {
        now.timeIntervalSince(generatedAt) > freshnessWindow
    }

    public static func from(textContext: TextContext, now: Date = Date()) -> SuggestionBinding {
        SuggestionBinding(
            stableFieldIdentity: textContext.stableFieldIdentity,
            focusedElementID: textContext.focusedElementID,
            contextFingerprint: SuggestionContextFingerprint.from(textContext: textContext),
            caretSnapshot: SuggestionCaretSnapshot.from(textContext: textContext),
            generatedAt: now
        )
    }
}

public struct SuggestionContextFingerprint: Equatable, Sendable {
    public let prefixHash: UInt64
    public let prefixLength: Int

    public let suffixHash: UInt64
    public let suffixLength: Int

    public let selectedRange: NSRange?
    public let domain: String?

    public init(
        prefixHash: UInt64,
        prefixLength: Int,
        suffixHash: UInt64,
        suffixLength: Int,
        selectedRange: NSRange?,
        domain: String?
    ) {
        self.prefixHash = prefixHash
        self.prefixLength = prefixLength
        self.suffixHash = suffixHash
        self.suffixLength = suffixLength
        self.selectedRange = selectedRange
        self.domain = domain
    }
}

public struct SuggestionCaretSnapshot: Equatable, Sendable {
    public let caretRect: CGRect?
    public let focusedElementRect: CGRect?
    public let quality: CaretGeometryQuality

    public init(
        caretRect: CGRect?,
        focusedElementRect: CGRect?,
        quality: CaretGeometryQuality
    ) {
        self.caretRect = caretRect
        self.focusedElementRect = focusedElementRect
        self.quality = quality
    }

    public static func from(textContext: TextContext) -> SuggestionCaretSnapshot {
        SuggestionCaretSnapshot(
            caretRect: textContext.caretRect,
            focusedElementRect: textContext.focusedElementRect,
            quality: textContext.caretGeometryQuality
        )
    }
}
