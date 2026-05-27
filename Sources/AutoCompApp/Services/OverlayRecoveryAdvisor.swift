import Combine
import Foundation

enum SafeOverlayMode {
    static let environmentKey = "AUTOCOMP_SAFE_OVERLAY_MODE"
    static let launchArgument = "--safe-overlay-mode"

    static var isEnabled: Bool {
        isEnabled(
            environment: ProcessInfo.processInfo.environment,
            arguments: ProcessInfo.processInfo.arguments
        )
    }

    static func isEnabled(
        environment: [String: String],
        arguments: [String] = []
    ) -> Bool {
        environment[environmentKey] == "1" || arguments.contains(launchArgument)
    }

    static let recommendation = "Set AUTOCOMP_SAFE_OVERLAY_MODE=1 and relaunch AutoComp."
}

@MainActor
final class OverlayRecoveryAdvisor: ObservableObject {
    static let failureThreshold = 3

    @Published private(set) var advancedOverlayFailureCount: Int

    private let defaults: UserDefaults
    private let key: String
    private let isSafeOverlayModeEnabled: () -> Bool

    init(
        defaults: UserDefaults = .standard,
        key: String = "advancedOverlayFailureCount",
        isSafeOverlayModeEnabled: @escaping () -> Bool = { SafeOverlayMode.isEnabled }
    ) {
        self.defaults = defaults
        self.key = key
        self.isSafeOverlayModeEnabled = isSafeOverlayModeEnabled
        self.advancedOverlayFailureCount = defaults.integer(forKey: key)
    }

    var safeModeStatusTitle: String {
        isSafeOverlayModeEnabled() ? "Active" : "Off"
    }

    var shouldRecommendSafeOverlayMode: Bool {
        !isSafeOverlayModeEnabled()
            && advancedOverlayFailureCount >= Self.failureThreshold
    }

    var recommendationMessage: String {
        if isSafeOverlayModeEnabled() {
            return "Safe simple mode is active. AutoComp uses simple popup or mirror preview routing."
        }

        if shouldRecommendSafeOverlayMode {
            return "\(SafeOverlayMode.recommendation) This disables advanced overlay placement while keeping acceptance shortcuts available."
        }

        return "AutoComp will recommend safe simple mode after repeated advanced overlay fallbacks."
    }

    func recordAdvancedOverlayFallback() {
        setFailureCount(min(advancedOverlayFailureCount + 1, 99))
        if shouldRecommendSafeOverlayMode {
            GeometryDebug.log("safe-overlay-mode recommended failureCount=\(advancedOverlayFailureCount)")
        }
    }

    func recordAdvancedOverlaySuccess() {
        guard advancedOverlayFailureCount != 0 else {
            return
        }
        setFailureCount(0)
    }

    func resetAdvancedOverlayFailures() {
        setFailureCount(0)
    }

    private func setFailureCount(_ count: Int) {
        advancedOverlayFailureCount = count
        defaults.set(count, forKey: key)
    }
}
