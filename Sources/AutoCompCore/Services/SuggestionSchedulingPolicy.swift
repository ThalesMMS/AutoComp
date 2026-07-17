import Foundation

public enum SuggestionSchedulingMutation: String, Codable, Sendable {
    case insert
    case delete
    case shortcut
    case acceptance
    case focusOrOther = "focus-or-other"
}

public enum SuggestionSchedulingHostPublishOutcome: String, Codable, Sendable {
    case published
    case timeout
    case cancelled
    case notAwaited = "not-awaited"
}

public enum SuggestionSchedulingReason: String, Codable, Sendable {
    case manualImmediate = "manual-immediate"
    case compositionActive = "composition-active"
    case adaptiveRoute = "adaptive-route"
    case adaptiveLatency = "adaptive-latency"
    case rapidTyping = "rapid-typing"
    case hostPublishConsumedWindow = "host-publish-consumed-window"
    case hostPublishTimeout = "host-publish-timeout"
    case fixedKillSwitch = "fixed-kill-switch"
}

public enum SuggestionSchedulingAction: String, Codable, Sendable {
    case debounce
    case generateImmediately = "generate-immediately"
    case suppress
}

public struct SuggestionSchedulingPolicy: Sendable {
    public static let currentPolicyVersion = 1

    public struct Configuration: Equatable, Sendable {
        public var adaptiveEnabled: Bool
        public var fixedDebounceMs: Int
        public var localTargetMs: Int
        public var appleTargetMs: Int
        public var remoteTargetMs: Int
        public var minimumTargetMs: Int
        public var maximumTargetMs: Int

        public init(
            adaptiveEnabled: Bool = true,
            fixedDebounceMs: Int = 250,
            localTargetMs: Int = 80,
            appleTargetMs: Int = 140,
            remoteTargetMs: Int = 260,
            minimumTargetMs: Int = 40,
            maximumTargetMs: Int = 480
        ) {
            self.adaptiveEnabled = adaptiveEnabled
            self.fixedDebounceMs = max(0, fixedDebounceMs)
            self.localTargetMs = max(0, localTargetMs)
            self.appleTargetMs = max(0, appleTargetMs)
            self.remoteTargetMs = max(0, remoteTargetMs)
            self.minimumTargetMs = max(0, minimumTargetMs)
            self.maximumTargetMs = max(self.minimumTargetMs, maximumTargetMs)
        }

        public static func environmentDefault(environment: [String: String] = ProcessInfo.processInfo.environment) -> Configuration {
            var configuration = Configuration()
            let disabled = environment["AUTOCOMP_DISABLE_ADAPTIVE_SCHEDULING"]?.lowercased()
            configuration.adaptiveEnabled = !["1", "true", "yes", "on"].contains(disabled ?? "")
            return configuration
        }
    }

    public struct Input: Equatable, Sendable {
        public var route: CompletionEngineKind
        public var invocation: SuggestionEligibilityInvocation
        public var mutation: SuggestionSchedulingMutation
        public var recentBackendLatencyMs: Int?
        public var hostPublishElapsedMs: Int
        public var hostPublishOutcome: SuggestionSchedulingHostPublishOutcome
        public var recentTypingIntervalMs: Int?
        public var isComposingText: Bool

        public init(
            route: CompletionEngineKind,
            invocation: SuggestionEligibilityInvocation,
            mutation: SuggestionSchedulingMutation,
            recentBackendLatencyMs: Int? = nil,
            hostPublishElapsedMs: Int = 0,
            hostPublishOutcome: SuggestionSchedulingHostPublishOutcome = .notAwaited,
            recentTypingIntervalMs: Int? = nil,
            isComposingText: Bool = false
        ) {
            self.route = route; self.invocation = invocation; self.mutation = mutation
            self.recentBackendLatencyMs = recentBackendLatencyMs.map { max(0, $0) }
            self.hostPublishElapsedMs = max(0, hostPublishElapsedMs)
            self.hostPublishOutcome = hostPublishOutcome
            self.recentTypingIntervalMs = recentTypingIntervalMs.map { max(0, $0) }
            self.isComposingText = isComposingText
        }
    }

    public struct Decision: Equatable, Sendable {
        public let targetDebounceMs: Int
        public let remainingDebounceMs: Int
        public let action: SuggestionSchedulingAction
        public let reason: SuggestionSchedulingReason
        public let recentBackendLatencyMs: Int?

        public var shouldGenerateImmediately: Bool { action == .generateImmediately }
    }

    public let configuration: Configuration

    public init(configuration: Configuration = .environmentDefault()) {
        self.configuration = configuration
    }

    public func decision(_ input: Input) -> Decision {
        if input.isComposingText {
            return Decision(
                targetDebounceMs: 0, remainingDebounceMs: 0, action: .suppress,
                reason: .compositionActive, recentBackendLatencyMs: input.recentBackendLatencyMs
            )
        }
        if input.invocation == .manual {
            return Decision(
                targetDebounceMs: 0, remainingDebounceMs: 0, action: .generateImmediately,
                reason: .manualImmediate, recentBackendLatencyMs: input.recentBackendLatencyMs
            )
        }
        guard configuration.adaptiveEnabled else {
            let fixed = configuration.fixedDebounceMs
            return Decision(
                targetDebounceMs: fixed,
                remainingDebounceMs: fixed,
                action: fixed == 0 ? .generateImmediately : .debounce,
                reason: .fixedKillSwitch,
                recentBackendLatencyMs: input.recentBackendLatencyMs
            )
        }

        let base = routeTarget(input.route)
        let expectedLatency = routeExpectedLatency(input.route)
        let latencyAdjustment = input.recentBackendLatencyMs.map {
            min(120, max(-30, ($0 - expectedLatency) / 4))
        } ?? 0
        let typingAdjustment: Int
        if input.mutation == .insert,
           let interval = input.recentTypingIntervalMs,
           interval <= 75 {
            typingAdjustment = 100
        } else if input.mutation == .insert,
                  let interval = input.recentTypingIntervalMs,
                  interval <= 140 {
            typingAdjustment = 50
        } else {
            typingAdjustment = 0
        }
        let mutationAdjustment: Int
        switch input.mutation {
        case .insert: mutationAdjustment = 0
        case .delete: mutationAdjustment = 30
        case .shortcut: mutationAdjustment = 60
        case .acceptance: mutationAdjustment = -30
        case .focusOrOther: mutationAdjustment = 0
        }
        let target = min(
            configuration.maximumTargetMs,
            max(configuration.minimumTargetMs, base + latencyAdjustment + typingAdjustment + mutationAdjustment)
        )
        let remaining = max(0, target - input.hostPublishElapsedMs)
        let reason: SuggestionSchedulingReason
        if input.hostPublishOutcome == .timeout {
            reason = .hostPublishTimeout
        } else if remaining == 0 && input.hostPublishElapsedMs > 0 {
            reason = .hostPublishConsumedWindow
        } else if typingAdjustment > 0 {
            reason = .rapidTyping
        } else if latencyAdjustment != 0 {
            reason = .adaptiveLatency
        } else {
            reason = .adaptiveRoute
        }
        return Decision(
            targetDebounceMs: target,
            remainingDebounceMs: remaining,
            action: remaining == 0 ? .generateImmediately : .debounce,
            reason: reason,
            recentBackendLatencyMs: input.recentBackendLatencyMs
        )
    }

    private func routeTarget(_ route: CompletionEngineKind) -> Int {
        switch route {
        case .localLlama: configuration.localTargetMs
        case .appleIntelligence: configuration.appleTargetMs
        case .remote: configuration.remoteTargetMs
        }
    }

    private func routeExpectedLatency(_ route: CompletionEngineKind) -> Int {
        switch route {
        case .localLlama: 100
        case .appleIntelligence: 250
        case .remote: 600
        }
    }
}

public struct SuggestionBackendLatencyHistory: Equatable, Sendable {
    public let maximumSamplesPerRoute: Int
    private var samples: [CompletionEngineKind: [Int]] = [:]

    public init(maximumSamplesPerRoute: Int = 7) {
        self.maximumSamplesPerRoute = max(1, maximumSamplesPerRoute)
    }

    public mutating func record(_ latencyMs: Int, for route: CompletionEngineKind) {
        guard latencyMs >= 0 else { return }
        var routeSamples = samples[route, default: []]
        routeSamples.append(min(latencyMs, 10_000))
        samples[route] = Array(routeSamples.suffix(maximumSamplesPerRoute))
    }

    public func robustLatencyMs(for route: CompletionEngineKind) -> Int? {
        let sorted = samples[route, default: []].sorted()
        guard !sorted.isEmpty else { return nil }
        return sorted[sorted.count / 2]
    }

    public func sampleCount(for route: CompletionEngineKind) -> Int {
        samples[route, default: []].count
    }
}
