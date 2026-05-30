import Foundation

/// A host-only domain pattern used for matching a focused browser context.
///
/// Supported forms:
/// - Exact host: `example.com`
/// - Subdomain wildcard: `*.example.com` (matches `a.example.com`, `b.c.example.com`, but not `example.com`)
/// - Catch-all: `*` (matches any non-empty host)
///
/// - Important: This type does not accept full URLs. It should only ever be created from a host string
///   or a user-entered host pattern that has been validated/sanitized.
public struct DomainPattern: Codable, Sendable, Hashable, Equatable {
    public enum Kind: String, Codable, Sendable {
        case exact
        case subdomainWildcard
        case any
    }

    public var kind: Kind
    public var value: String

    public init(kind: Kind, value: String) {
        self.kind = kind
        self.value = value
    }

    public static func exactHost(_ host: String) -> DomainPattern {
        DomainPattern(kind: .exact, value: host.lowercased())
    }

    public static func wildcardSubdomains(_ baseHost: String) -> DomainPattern {
        DomainPattern(kind: .subdomainWildcard, value: baseHost.lowercased())
    }

    public static var any: DomainPattern {
        DomainPattern(kind: .any, value: "*")
    }

    /// Parses a user-entered pattern string.
    ///
    /// Returns `nil` for empty/whitespace-only strings.
    public init?(rawString: String) {
        let trimmed = rawString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if trimmed == "*" {
            self.kind = .any
            self.value = "*"
            return
        }

        let lowercased = trimmed.lowercased()
        if lowercased.hasPrefix("*.") {
            let host = String(lowercased.dropFirst(2))
            self.kind = .subdomainWildcard
            self.value = host
        } else {
            self.kind = .exact
            self.value = lowercased
        }
    }

    /// A canonical string representation suitable for UI and persistence.
    public var rawString: String {
        switch kind {
        case .any:
            return "*"
        case .exact:
            return value
        case .subdomainWildcard:
            return "*.\(value)"
        }
    }
}
