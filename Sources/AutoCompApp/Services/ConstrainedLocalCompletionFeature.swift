import Foundation

enum ConstrainedLocalCompletionFeature {
    static let environmentKey = "AUTOCOMP_ENABLE_CONSTRAINED_LOCAL_COMPLETION"
    static let multiBranchEnvironmentKey = "AUTOCOMP_ENABLE_LOCAL_MULTIBRANCH_DECODER"
    static let tokenProfilePathEnvironmentKey = "AUTOCOMP_LOCAL_TOKEN_PROFILE_PATH"

    static func isEnabled(values: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let value = values[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return ["1", "true", "yes", "on"].contains(value)
    }

    static func isMultiBranchEnabled(values: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let value = values[multiBranchEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else { return false }
        return ["1", "true", "yes", "on"].contains(value)
    }

    static func tokenProfilePath(
        modelPath: String,
        values: [String: String] = ProcessInfo.processInfo.environment
    ) -> String {
        let explicit = values[tokenProfilePathEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return explicit.isEmpty ? modelPath + ".actkp" : explicit
    }
}
