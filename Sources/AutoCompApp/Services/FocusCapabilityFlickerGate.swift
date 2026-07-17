import Foundation

enum FocusCapabilityFlickerDecision: Equatable {
    case suppressTransient(reason: String)
    case apply(reason: String)
}

struct FocusCapabilityFlickerStats: Equatable {
    private(set) var suppressedReads = 0
    private(set) var appliedReads = 0
    private(set) var lastReason: String?

    mutating func record(_ decision: FocusCapabilityFlickerDecision) {
        switch decision {
        case .suppressTransient(let reason):
            suppressedReads += 1
            lastReason = reason
        case .apply(let reason):
            appliedReads += 1
            lastReason = reason
        }
    }
}

struct FocusCapabilityFlickerGate {
    private let consecutiveReadThreshold: Int
    private var consecutiveTransientReads = 0
    private(set) var stats = FocusCapabilityFlickerStats()

    init(consecutiveReadThreshold: Int = 2) {
        self.consecutiveReadThreshold = max(2, consecutiveReadThreshold)
    }

    mutating func evaluate(
        capability: FocusFieldCapability,
        sameStableField: Bool
    ) -> FocusCapabilityFlickerDecision {
        let decision: FocusCapabilityFlickerDecision
        if capability == .secureOrUnsupported {
            consecutiveTransientReads = 0
            decision = .apply(reason: "secure-or-unsupported-immediate")
        } else if !sameStableField {
            consecutiveTransientReads = 0
            decision = .apply(reason: "focus-identity-changed")
        } else if capability == .unreadableText || capability == .unavailable {
            consecutiveTransientReads += 1
            if consecutiveTransientReads < consecutiveReadThreshold {
                decision = .suppressTransient(reason: "same-field-transient-capability")
            } else {
                consecutiveTransientReads = 0
                decision = .apply(reason: "consecutive-transient-threshold")
            }
        } else {
            consecutiveTransientReads = 0
            decision = .apply(reason: "non-transient-capability")
        }
        stats.record(decision)
        return decision
    }

    mutating func recordSuccessfulRead() {
        consecutiveTransientReads = 0
    }

    mutating func reset() {
        consecutiveTransientReads = 0
    }
}
