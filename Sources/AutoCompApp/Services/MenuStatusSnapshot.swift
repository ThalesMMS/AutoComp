import AutoCompCore
import Foundation

struct MenuStatusItem: Identifiable, Equatable {
    let id: String
    let title: String
    let value: String
    let action: String
}

struct MenuStatusSnapshot: Equatable {
    let items: [MenuStatusItem]

    static func make(
        accessibilityTrusted: Bool,
        inputMonitoringAllowed: Bool,
        backendStatusSummary: BackendStatusSummary,
        inputMethod: SuggestionDiagnostics.InputMethod,
        focus: SuggestionDiagnostics.Focus?,
        focusFailure: SuggestionDiagnostics.FocusFailure?,
        lastDecision: SuggestionDiagnostics.LastDecision? = nil,
        compatibilityDecision: CompatibilityDecision?,
        autocompleteEnabled: Bool,
        productivityMetrics: ProductivityMetricsSnapshot? = nil,
        now: Date = Date()
    ) -> MenuStatusSnapshot {
        var items = [
            backendItem(backendStatusSummary, now: now),
            accessibilityItem(accessibilityTrusted),
            inputItem(inputMonitoringAllowed),
            inputMethodItem(inputMethod),
            focusItem(
                accessibilityTrusted: accessibilityTrusted,
                focus: focus,
                focusFailure: focusFailure,
                compatibilityDecision: compatibilityDecision
            ),
            modeItem(
                compatibilityDecision: compatibilityDecision,
                autocompleteEnabled: autocompleteEnabled
            )
        ]

        if let productivityMetrics {
            items.append(productivityItem(productivityMetrics))
        }

        if let decision = lastDecision ?? permissionDecision(
            accessibilityTrusted: accessibilityTrusted,
            inputMonitoringAllowed: inputMonitoringAllowed
        ) {
            items.append(lastDecisionItem(decision))
        }

        return MenuStatusSnapshot(items: items)
    }

    private static func backendItem(
        _ summary: BackendStatusSummary,
        now: Date
    ) -> MenuStatusItem {
        let action: String
        switch summary.state {
        case .connected:
            action = "Backend is ready."
        case .paused:
            action = summary.menuTitle(at: now)
        case .disconnected:
            action = summary.menuTitle(at: now)
        }

        return MenuStatusItem(
            id: "backend",
            title: "Backend",
            value: summary.state.rawValue,
            action: action
        )
    }

    private static func accessibilityItem(_ trusted: Bool) -> MenuStatusItem {
        MenuStatusItem(
            id: "accessibility",
            title: "AX",
            value: trusted ? "OK" : "Missing",
            action: trusted ? "Accessibility permission is enabled." : "Enable Accessibility permission."
        )
    }

    private static func inputItem(_ allowed: Bool) -> MenuStatusItem {
        MenuStatusItem(
            id: "input",
            title: "Input",
            value: allowed ? "OK" : "Missing",
            action: allowed ? "Input Monitoring is enabled." : "Enable Input Monitoring for shortcuts."
        )
    }

    private static func inputMethodItem(_ inputMethod: SuggestionDiagnostics.InputMethod) -> MenuStatusItem {
        let value: String
        let action: String
        switch inputMethod.summary {
        case "ASCII":
            value = "ASCII"
            action = "Automatic suggestions can run."
        case "non-ASCII":
            value = "non-ASCII"
            action = "Use manual trigger or switch input source."
        case "composing":
            value = "Composing"
            action = "Finish IME composition before accepting suggestions."
        default:
            value = inputMethod.summary
            action = "Current input source status."
        }

        return MenuStatusItem(
            id: "ime",
            title: "IME",
            value: value,
            action: action
        )
    }

    private static func lastDecisionItem(_ decision: SuggestionDiagnostics.LastDecision) -> MenuStatusItem {
        MenuStatusItem(
            id: "lastDecision",
            title: "Last decision",
            value: decision.state.rawValue.capitalized,
            action: "\(decision.reason.rawValue): \(decision.action)"
        )
    }

    private static func permissionDecision(
        accessibilityTrusted: Bool,
        inputMonitoringAllowed: Bool
    ) -> SuggestionDiagnostics.LastDecision? {
        if !accessibilityTrusted {
            return SuggestionDiagnostics.LastDecision(
                state: .blocked,
                reason: .missingPermission,
                action: "Enable Accessibility permission."
            )
        }

        if !inputMonitoringAllowed {
            return SuggestionDiagnostics.LastDecision(
                state: .blocked,
                reason: .missingPermission,
                action: "Enable Input Monitoring for shortcuts."
            )
        }

        return nil
    }

    private static func focusItem(
        accessibilityTrusted: Bool,
        focus: SuggestionDiagnostics.Focus?,
        focusFailure: SuggestionDiagnostics.FocusFailure?,
        compatibilityDecision: CompatibilityDecision?
    ) -> MenuStatusItem {
        if !accessibilityTrusted {
            return MenuStatusItem(
                id: "focus",
                title: "Focus",
                value: "Blocked",
                action: "Enable Accessibility permission."
            )
        }

        if let focusFailure {
            return MenuStatusItem(
                id: "focus",
                title: "Focus",
                value: focusFailure.status.rawValue,
                action: focusFailure.action
            )
        }

        if let compatibilityDecision,
           !compatibilityDecision.enabled || compatibilityDecision.mode == .disabled {
            return MenuStatusItem(
                id: "focus",
                title: "Focus",
                value: "Blocked",
                action: compatibilityAction(for: compatibilityDecision)
            )
        }

        if let compatibilityDecision,
           compatibilityDecision.profile.status == .unsupported {
            return MenuStatusItem(
                id: "focus",
                title: "Focus",
                value: "Blocked",
                action: compatibilityAction(for: compatibilityDecision)
            )
        }

        if focus != nil {
            return MenuStatusItem(
                id: "focus",
                title: "Focus",
                value: "Supported",
                action: compatibilityDecision?.setupMessage ?? "Focused field is readable."
            )
        }

        return MenuStatusItem(
            id: "focus",
            title: "Focus",
            value: "Unsupported",
            action: "Focus a supported text field."
        )
    }

    private static func modeItem(
        compatibilityDecision: CompatibilityDecision?,
        autocompleteEnabled: Bool
    ) -> MenuStatusItem {
        guard autocompleteEnabled else {
            return MenuStatusItem(
                id: "mode",
                title: "Mode",
                value: "Disabled",
                action: "Autocomplete is disabled from the menu."
            )
        }

        guard let compatibilityDecision else {
            return MenuStatusItem(
                id: "mode",
                title: "Mode",
                value: "Automatic",
                action: "Waiting for focused app context."
            )
        }

        if !compatibilityDecision.enabled
            || compatibilityDecision.mode == .disabled
            || compatibilityDecision.overrideMode == .disabled {
            return MenuStatusItem(
                id: "mode",
                title: "Mode",
                value: "Disabled",
                action: compatibilityAction(for: compatibilityDecision)
            )
        }

        if compatibilityDecision.overrideMode == .manualOnly {
            return MenuStatusItem(
                id: "mode",
                title: "Mode",
                value: "Manual-only",
                action: "Use the manual trigger in this app or domain."
            )
        }

        if compatibilityDecision.mode == .mirrorWindow {
            return MenuStatusItem(
                id: "mode",
                title: "Mode",
                value: "Mirror",
                action: "Suggestions use the mirror window for this app."
            )
        }

        return MenuStatusItem(
            id: "mode",
            title: "Mode",
            value: "Automatic",
            action: "Automatic suggestions are enabled here."
        )
    }

    private static func compatibilityAction(for decision: CompatibilityDecision) -> String {
        if let setupMessage = decision.setupMessage {
            return setupMessage
        }
        if !decision.profile.notes.isEmpty {
            return decision.profile.notes
        }
        if decision.overrideMode == .disabled {
            return "Current app or domain is disabled."
        }
        return "Current app is not supported."
    }

    private static func productivityItem(_ metrics: ProductivityMetricsSnapshot) -> MenuStatusItem {
        MenuStatusItem(
            id: "metrics",
            title: "Metrics",
            value: metrics.menuValue,
            action: metrics.menuAction
        )
    }
}
