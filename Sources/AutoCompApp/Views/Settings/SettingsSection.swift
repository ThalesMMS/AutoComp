import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general = "General"
    case setup = "Setup"
    case model = "Model"
    case shortcuts = "Shortcuts"
    case privacy = "Privacy"
    case apps = "Apps"
    case health = "Health"
    case statistics = "Statistics"
    case developer = "Developer"

    static let allCases: [SettingsSection] = [
        .general,
        .setup,
        .model,
        .shortcuts,
        .privacy,
        .apps,
        .health,
        .statistics,
        .developer
    ]

    var id: String { rawValue }
    var title: String { rawValue }

    var sidebarDescription: String {
        switch self {
        case .general:
            return "Everyday controls"
        case .setup:
            return "Permissions and readiness"
        case .model:
            return "Completion backend"
        case .shortcuts:
            return "Acceptance keys"
        case .privacy:
            return "Local data controls"
        case .apps:
            return "Compatibility rules"
        case .health:
            return "Runtime status"
        case .statistics:
            return "Usage and latency"
        case .developer:
            return "Advanced diagnostics"
        }
    }

    var systemImage: String {
        switch self {
        case .general:
            return "gearshape"
        case .setup:
            return "checklist"
        case .model:
            return "cpu"
        case .shortcuts:
            return "keyboard"
        case .privacy:
            return "hand.raised"
        case .apps:
            return "rectangle.stack"
        case .health:
            return "heart.text.square"
        case .statistics:
            return "chart.bar.xaxis"
        case .developer:
            return "hammer"
        }
    }

    var accentColor: Color {
        switch self {
        case .general:
            return .blue
        case .setup:
            return .green
        case .model:
            return .purple
        case .shortcuts:
            return .orange
        case .privacy:
            return .indigo
        case .apps:
            return .teal
        case .health:
            return .mint
        case .statistics:
            return .cyan
        case .developer:
            return .gray
        }
    }
}
