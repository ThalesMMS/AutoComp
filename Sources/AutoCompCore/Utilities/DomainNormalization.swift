import Foundation

/// Shared domain + path normalization and specificity candidate generation.
///
/// This is used for features that store per-domain rules (privacy collection rules,
/// compatibility overrides, etc.) and need consistent matching behavior.
///
/// Canonical form matches legacy behavior:
/// - Trim whitespace/newlines
/// - Lowercase
/// - Strip leading http:// or https://
/// - Strip everything after first '?' or '#'
/// - Trim leading/trailing '/'
///
/// Result is typically in the form:
/// - "example.com"
/// - "example.com/a/b"
public enum DomainNormalization {
    /// Returns a canonical domain string (optionally including a path), or nil if
    /// the normalized value would be empty.
    public static func canonicalDomainString(from input: String) -> String? {
        let normalized = canonicalDomainStringAllowingEmpty(from: input)
        return normalized.isEmpty ? nil : normalized
    }

    /// Same as `canonicalDomainString(from:)` but returns an empty string instead of nil.
    public static func canonicalDomainStringAllowingEmpty(from input: String) -> String {
        var normalized = input
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if normalized.hasPrefix("https://") {
            normalized.removeFirst("https://".count)
        } else if normalized.hasPrefix("http://") {
            normalized.removeFirst("http://".count)
        }

        if let fragmentIndex = normalized.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            normalized = String(normalized[..<fragmentIndex])
        }

        return normalized.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    }

    /// Produces match candidates ordered from most-specific to least-specific.
    ///
    /// Examples:
    /// - input: "example.com/a/b/c" -> ["example.com/a/b/c", "example.com/a/b", "example.com/a", "example.com"]
    /// - input: "example.com" -> ["example.com"]
    /// - input: "" -> []
    public static func specificityCandidates(for input: String) -> [String] {
        guard let canonical = canonicalDomainString(from: input) else {
            return []
        }
        return specificityCandidates(forCanonicalDomainString: canonical)
    }

    /// Produces match candidates from an already-canonical domain string.
    ///
    /// `canonical` must already have had schemes, query/fragment and leading/trailing slashes removed.
    public static func specificityCandidates(forCanonicalDomainString canonical: String) -> [String] {
        let components = canonical.split(separator: "/").map(String.init)
        guard components.count > 1 else {
            return [canonical]
        }

        var candidates: [String] = []
        for count in stride(from: components.count, through: 1, by: -1) {
            candidates.append(components.prefix(count).joined(separator: "/"))
        }
        return candidates
    }
}
