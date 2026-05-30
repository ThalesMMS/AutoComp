import Foundation

struct GuidedSetupStep: Identifiable, Equatable {
    enum Status: Equatable {
        case incomplete
        case complete
        case blocked(String)
    }

    enum PrimaryAction: Equatable {
        case requestPermission(PermissionKind)
        case openSystemSettings(PermissionKind)
        case recheck
        case relaunchApp
        case none

        var title: String {
            switch self {
            case .requestPermission(let kind):
                return kind.requestButtonTitle
            case .openSystemSettings(let kind):
                return kind.openSettingsButtonTitle
            case .recheck:
                return "Recheck"
            case .relaunchApp:
                return "Relaunch AutoComp"
            case .none:
                return ""
            }
        }
    }

    let id: String
    let number: Int
    let title: String
    let detail: String
    let isMandatory: Bool
    let status: Status
    let primaryAction: PrimaryAction
    let permissionKind: PermissionKind?

    var isComplete: Bool {
        status == .complete
    }

    /// Extra copy shown above the checklist to guide the user back into AutoComp.
    ///
    /// Only shown when the app has detected that the permission is enabled in System Settings,
    /// but the process must be relaunched for the permission to take effect.
    var relaunchGuidanceBannerMessage: String? {
        guard primaryAction == .relaunchApp else { return nil }
        return "AutoComp can see that \(title) is enabled in System Settings, but it won’t take effect until you relaunch AutoComp."
    }

    /// Step-local guidance copy used in the checklist detail text.
    /// Only present when a relaunch is required.
    var relaunchGuidanceDetail: String? {
        guard primaryAction == .relaunchApp else { return nil }
        return "Return to AutoComp, then click Relaunch AutoComp to apply this change."
    }
}
