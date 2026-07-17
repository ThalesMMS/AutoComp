import AutoCompCore
import Foundation

enum StreamingCompletionFeature {
    static let localLlamaEnvironmentKey = "AUTOCOMP_ENABLE_LOCAL_STREAMING"

    static func configuration(environment: [String: String] = ProcessInfo.processInfo.environment) -> StreamingCompletionConfiguration {
        guard isEnabled(environment[localLlamaEnvironmentKey]) else { return .disabled }
        return StreamingCompletionConfiguration(enabledRoutes: [.localLlama])
    }

    private static func isEnabled(_ value: String?) -> Bool {
        guard let value else { return false }
        return ["1", "true", "yes", "on"].contains(value.lowercased())
    }
}
