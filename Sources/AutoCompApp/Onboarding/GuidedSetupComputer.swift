import Foundation

struct GuidedSetupState: Equatable {
    let steps: [GuidedSetupStep]
    let currentStepID: GuidedSetupStep.ID?
    let progress: GuidedSetupProgress
    let primaryAction: GuidedSetupStep.PrimaryAction

    var currentStep: GuidedSetupStep? {
        guard let currentStepID else { return nil }
        return steps.first { $0.id == currentStepID }
    }
}

enum GuidedSetupComputer {
    static func compute(from permissionPresentations: [PermissionPresentation]) -> GuidedSetupState {
        let ordered = orderedPresentations(permissionPresentations)

        let steps: [GuidedSetupStep] = ordered.enumerated().map { index, presentation in
            GuidedSetupStep(
                id: presentation.kind.rawValue,
                number: index + 1,
                title: presentation.title,
                detail: stepDetail(for: presentation),
                isMandatory: presentation.requirement == .required,
                status: status(for: presentation),
                primaryAction: stepPrimaryAction(for: presentation),
                permissionKind: presentation.kind
            )
        }

        let mandatorySteps = steps.filter { $0.isMandatory }
        let completedMandatory = mandatorySteps.filter { $0.isComplete }.count
        let progress = GuidedSetupProgress(
            completedMandatorySteps: completedMandatory,
            totalMandatorySteps: mandatorySteps.count
        )

        let current = steps.first { !$0.isComplete && $0.isMandatory } ?? steps.first { !$0.isComplete }
        let primaryAction = current?.primaryAction ?? .none

        return GuidedSetupState(
            steps: steps,
            currentStepID: current?.id,
            progress: progress,
            primaryAction: primaryAction
        )
    }

    private static func orderedPresentations(_ presentations: [PermissionPresentation]) -> [PermissionPresentation] {
        let priority: [PermissionKind: Int] = [
            .accessibility: 0,
            .inputMonitoring: 1,
            .screenRecording: 2
        ]

        return presentations.sorted {
            (priority[$0.kind] ?? 999, $0.title) < (priority[$1.kind] ?? 999, $1.title)
        }
    }

    private static func status(for presentation: PermissionPresentation) -> GuidedSetupStep.Status {
        if presentation.isComplete {
            return .complete
        }
        if presentation.needsRelaunch {
            return .blocked("Relaunch required")
        }
        return .incomplete
    }

    private static func stepDetail(for presentation: PermissionPresentation) -> String {
        if presentation.needsRelaunch {
            return "\(presentation.title) is enabled in System Settings, but it won’t take effect until AutoComp is relaunched."
        }
        return presentation.message
    }

    private static func stepPrimaryAction(for presentation: PermissionPresentation) -> GuidedSetupStep.PrimaryAction {
        if presentation.isComplete {
            return .none
        }
        if presentation.needsRelaunch {
            return .relaunchApp
        }
        return .requestPermission(presentation.kind)
    }
}
