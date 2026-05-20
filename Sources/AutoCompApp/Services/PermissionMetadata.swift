import Foundation

enum PermissionRequirement: Equatable {
    case required
    case optional
}

enum PermissionStatus: Equatable {
    case enabled
    case missing
    case requesting
    case relaunchNeeded

    func displayTitle(requirement: PermissionRequirement) -> String {
        switch self {
        case .enabled:
            return "Enabled"
        case .missing:
            return requirement == .required ? "Required" : "Optional"
        case .requesting:
            return "Requesting"
        case .relaunchNeeded:
            return "Relaunch Required"
        }
    }
}

enum PermissionKind: String, CaseIterable, Identifiable {
    case accessibility
    case inputMonitoring
    case screenRecording

    var id: String { rawValue }

    var title: String {
        switch self {
        case .accessibility:
            return "Accessibility"
        case .inputMonitoring:
            return "Input Monitoring"
        case .screenRecording:
            return "Screen Recording"
        }
    }

    var systemImage: String {
        switch self {
        case .accessibility:
            return "lock.shield"
        case .inputMonitoring:
            return "keyboard"
        case .screenRecording:
            return "rectangle.dashed"
        }
    }

    var requirement: PermissionRequirement {
        switch self {
        case .accessibility, .inputMonitoring:
            return .required
        case .screenRecording:
            return .optional
        }
    }

    var baselineDescription: String {
        switch self {
        case .accessibility:
            return "Required to read the active text field and insert accepted completions."
        case .inputMonitoring:
            return "Required for Tab and Right Shift acceptance."
        case .screenRecording:
            return "Optional; improves visible context capture."
        }
    }

    var settingsLocation: String {
        switch self {
        case .accessibility:
            return "Privacy & Security > Accessibility"
        case .inputMonitoring:
            return "Privacy & Security > Input Monitoring"
        case .screenRecording:
            return "Privacy & Security > Screen Recording"
        }
    }

    var requestButtonTitle: String {
        switch self {
        case .accessibility:
            return "Enable Accessibility"
        case .inputMonitoring:
            return "Enable Input Monitoring"
        case .screenRecording:
            return "Enable Screen Recording"
        }
    }

    var openSettingsButtonTitle: String {
        switch self {
        case .accessibility:
            return "Open Accessibility Settings"
        case .inputMonitoring:
            return "Open Input Monitoring Settings"
        case .screenRecording:
            return "Open Screen Recording Settings"
        }
    }

    var settingsURL: URL {
        switch self {
        case .accessibility:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        case .inputMonitoring:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        case .screenRecording:
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")!
        }
    }
}

struct PermissionStateSnapshot: Equatable {
    var accessibilityTrusted: Bool
    var inputMonitoringAllowed: Bool
    var inputMonitoringStatus: String
    var screenRecordingAllowed: Bool
    var screenRecordingNeedsRelaunch: Bool
    var screenRecordingStatus: String
}

struct PermissionPresentation: Identifiable, Equatable {
    let kind: PermissionKind
    let title: String
    let systemImage: String
    let requirement: PermissionRequirement
    let status: PermissionStatus
    let statusTitle: String
    let message: String
    let nextActionTitle: String
    let requestButtonTitle: String
    let openSettingsButtonTitle: String
    let settingsURL: URL

    var id: PermissionKind { kind }
    var isComplete: Bool { status == .enabled }
    var needsRelaunch: Bool { status == .relaunchNeeded }
}

enum PermissionPresentationFactory {
    static func presentation(for kind: PermissionKind, state: PermissionStateSnapshot) -> PermissionPresentation {
        let status = resolvedStatus(for: kind, state: state)
        return PermissionPresentation(
            kind: kind,
            title: kind.title,
            systemImage: kind.systemImage,
            requirement: kind.requirement,
            status: status,
            statusTitle: status.displayTitle(requirement: kind.requirement),
            message: message(for: kind, status: status, state: state),
            nextActionTitle: nextAction(for: kind, status: status),
            requestButtonTitle: kind.requestButtonTitle,
            openSettingsButtonTitle: kind.openSettingsButtonTitle,
            settingsURL: kind.settingsURL
        )
    }

    private static func resolvedStatus(for kind: PermissionKind, state: PermissionStateSnapshot) -> PermissionStatus {
        switch kind {
        case .accessibility:
            return state.accessibilityTrusted ? .enabled : .missing
        case .inputMonitoring:
            if state.inputMonitoringAllowed {
                return .enabled
            }
            if state.inputMonitoringStatus.localizedCaseInsensitiveContains("requesting") {
                return .requesting
            }
            return .missing
        case .screenRecording:
            if state.screenRecordingAllowed {
                return .enabled
            }
            if state.screenRecordingNeedsRelaunch {
                return .relaunchNeeded
            }
            return .missing
        }
    }

    private static func message(
        for kind: PermissionKind,
        status: PermissionStatus,
        state: PermissionStateSnapshot
    ) -> String {
        switch kind {
        case .accessibility:
            switch status {
            case .enabled:
                return "Enabled for this app."
            default:
                return "\(kind.baselineDescription) Approval must be granted in System Settings at \(kind.settingsLocation)."
            }
        case .inputMonitoring:
            switch status {
            case .enabled:
                return "Enabled for this app."
            case .requesting:
                return "Waiting for approval in System Settings at \(kind.settingsLocation)."
            default:
                return "\(state.inputMonitoringStatus) Approval must be granted in System Settings at \(kind.settingsLocation)."
            }
        case .screenRecording:
            switch status {
            case .enabled:
                return "Enabled for this app."
            case .relaunchNeeded:
                return state.screenRecordingStatus
            default:
                return "\(state.screenRecordingStatus) You can approve it in System Settings at \(kind.settingsLocation)."
            }
        }
    }

    private static func nextAction(for kind: PermissionKind, status: PermissionStatus) -> String {
        switch status {
        case .enabled:
            return "No action needed."
        case .missing:
            return "Open \(kind.settingsLocation), enable AutoComp, then recheck."
        case .requesting:
            return "Approve AutoComp in \(kind.settingsLocation), then recheck."
        case .relaunchNeeded:
            return "Relaunch AutoComp after enabling \(kind.title)."
        }
    }
}
