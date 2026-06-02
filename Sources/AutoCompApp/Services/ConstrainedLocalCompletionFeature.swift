import Foundation

enum ConstrainedLocalCompletionFeature {
    static let environmentKey = "AUTOCOMP_ENABLE_CONSTRAINED_LOCAL_COMPLETION"

    static func isEnabled(values: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        guard let value = values[environmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() else {
            return false
        }
        return ["1", "true", "yes", "on"].contains(value)
    }
}
