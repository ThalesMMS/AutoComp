public enum AcceptanceTextDelta {
    public static func trimmingSuffixOverlap(token: String, suffix: String?) -> String {
        guard let suffix, !suffix.isEmpty, !token.isEmpty else {
            return token
        }

        guard token.hasSuffix(suffix) else {
            return token
        }

        return String(token.dropLast(suffix.count))
    }
}
