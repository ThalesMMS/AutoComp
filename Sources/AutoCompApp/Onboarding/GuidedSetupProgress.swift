import Foundation

struct GuidedSetupProgress: Equatable {
    let completedMandatorySteps: Int
    let totalMandatorySteps: Int

    var fractionComplete: Double {
        guard totalMandatorySteps > 0 else { return 1 }
        return Double(completedMandatorySteps) / Double(totalMandatorySteps)
    }

    var isComplete: Bool {
        completedMandatorySteps >= totalMandatorySteps
    }
}
