import AutoCompCore
import AppKit
import SwiftUI

enum SettingsVisualState: String, CaseIterable, Identifiable {
    case ok
    case warning
    case error
    case disabled
    case pending

    var id: String { rawValue }

    var title: String {
        switch self {
        case .ok:
            return "OK"
        case .warning:
            return "Warning"
        case .error:
            return "Error"
        case .disabled:
            return "Disabled"
        case .pending:
            return "Pending"
        }
    }

    var systemImage: String {
        switch self {
        case .ok:
            return "checkmark.circle.fill"
        case .warning:
            return "exclamationmark.triangle.fill"
        case .error:
            return "xmark.octagon.fill"
        case .disabled:
            return "minus.circle.fill"
        case .pending:
            return "clock.fill"
        }
    }

    var tint: Color {
        switch self {
        case .ok:
            return .green
        case .warning:
            return .orange
        case .error:
            return .red
        case .disabled:
            return .gray
        case .pending:
            return .blue
        }
    }

    static func permission(_ status: PermissionStatus, requirement: PermissionRequirement) -> SettingsVisualState {
        switch status {
        case .enabled:
            return .ok
        case .missing:
            return requirement == .required ? .error : .disabled
        case .requesting:
            return .pending
        case .relaunchNeeded:
            return .warning
        }
    }

    static func health(_ status: HealthStatus) -> SettingsVisualState {
        switch status {
        case .ok:
            return .ok
        case .warn:
            return .warning
        case .fail:
            return .error
        case .unknown:
            return .pending
        }
    }

    static func backend(_ state: BackendConnectionState) -> SettingsVisualState {
        switch state {
        case .connected:
            return .ok
        case .disconnected:
            return .error
        case .paused:
            return .warning
        }
    }

    static func modelDownload(_ state: ModelDownloadState) -> SettingsVisualState {
        switch state {
        case .ready:
            return .ok
        case .failed:
            return .error
        case .loading:
            return .pending
        case .idle:
            return .disabled
        }
    }

    static func compatibility(_ status: CompatibilityStatus) -> SettingsVisualState {
        switch status {
        case .works:
            return .ok
        case .setupNeeded:
            return .warning
        case .partial, .mirrorOnly:
            return .pending
        case .unsupported:
            return .disabled
        }
    }

    static func activation(_ mode: SuggestionActivationMode) -> SettingsVisualState {
        switch mode {
        case .automatic:
            return .ok
        case .manualOnly:
            return .warning
        case .disabled:
            return .disabled
        }
    }
}

struct StatusBadge: View {
    let state: SettingsVisualState
    let title: String

    init(_ title: String? = nil, state: SettingsVisualState) {
        self.state = state
        self.title = title ?? state.title
    }

    var body: some View {
        Label {
            Text(title)
                .font(.caption.weight(.semibold))
        } icon: {
            Image(systemName: state.systemImage)
                .imageScale(.small)
        }
        .labelStyle(.titleAndIcon)
        .foregroundStyle(state.tint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(state.tint.opacity(0.12), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(state.title): \(title)")
    }
}

struct StatusDot: View {
    let state: SettingsVisualState
    let label: String

    var body: some View {
        Circle()
            .fill(state.tint)
            .frame(width: 9, height: 9)
            .accessibilityLabel("\(state.title): \(label)")
    }
}

struct SettingsInfoCard<Content: View>: View {
    let title: String
    let subtitle: String?
    let state: SettingsVisualState?
    let statusTitle: String?
    let systemImage: String?
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        subtitle: String? = nil,
        state: SettingsVisualState? = nil,
        statusTitle: String? = nil,
        systemImage: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.subtitle = subtitle
        self.state = state
        self.statusTitle = statusTitle
        self.systemImage = systemImage
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(state?.tint ?? .secondary)
                        .frame(width: 20)
                        .accessibilityHidden(true)
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body.weight(.semibold))
                    if let subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer(minLength: 8)

                if let state {
                    StatusBadge(statusTitle, state: state)
                }
            }

            content()
        }
        .padding(10)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.secondary.opacity(0.16), lineWidth: 1)
        )
    }
}

extension SettingsInfoCard where Content == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        state: SettingsVisualState? = nil,
        statusTitle: String? = nil,
        systemImage: String? = nil
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            state: state,
            statusTitle: statusTitle,
            systemImage: systemImage
        ) {
            EmptyView()
        }
    }
}

struct SettingsActionRow<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let state: SettingsVisualState?
    let statusTitle: String?
    @ViewBuilder let trailing: () -> Trailing

    init(
        title: String,
        subtitle: String? = nil,
        state: SettingsVisualState? = nil,
        statusTitle: String? = nil,
        @ViewBuilder trailing: @escaping () -> Trailing
    ) {
        self.title = title
        self.subtitle = subtitle
        self.state = state
        self.statusTitle = statusTitle
        self.trailing = trailing
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 8)

            if let state {
                StatusBadge(statusTitle, state: state)
            }

            trailing()
        }
    }
}

extension SettingsActionRow where Trailing == EmptyView {
    init(
        title: String,
        subtitle: String? = nil,
        state: SettingsVisualState? = nil,
        statusTitle: String? = nil
    ) {
        self.init(
            title: title,
            subtitle: subtitle,
            state: state,
            statusTitle: statusTitle
        ) {
            EmptyView()
        }
    }
}

struct PermissionCard<Actions: View>: View {
    let permission: PermissionPresentation
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        SettingsInfoCard(
            title: permission.title,
            subtitle: shortSummary,
            state: SettingsVisualState.permission(permission.status, requirement: permission.requirement),
            statusTitle: permission.statusTitle,
            systemImage: permission.systemImage
        ) {
            if !permission.isComplete {
                SettingsActionRow(
                    title: "Next step",
                    subtitle: nextStepSummary,
                    state: SettingsVisualState.permission(permission.status, requirement: permission.requirement),
                    statusTitle: nextStepStatusTitle
                )
            }

            DisclosureGroup("Technical details") {
                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Access level", value: permission.requirementDetail)
                    LabeledContent("System setting", value: permission.settingsLocation)
                    LabeledContent("Reason", value: permission.message)
                    LabeledContent("Action", value: permission.nextActionTitle)
                }
            }

            if !permission.isComplete {
                HStack(spacing: 8) {
                    actions()
                }
            }
        }
    }

    private var shortSummary: String {
        switch permission.status {
        case .enabled:
            return "Ready."
        case .missing:
            return permission.requirement == .required
                ? "Needed for suggestions."
                : "Only for visual context."
        case .requesting:
            return "Waiting for approval."
        case .relaunchNeeded:
            return "Relaunch to finish."
        }
    }

    private var nextStepSummary: String {
        switch permission.status {
        case .enabled:
            return "No action needed."
        case .missing:
            return permission.requirement == .required
                ? "Open System Settings and enable AutoComp."
                : "Enable it only when visual context is useful."
        case .requesting:
            return "Approve AutoComp in System Settings, then recheck."
        case .relaunchNeeded:
            return "Relaunch AutoComp to apply the permission."
        }
    }

    private var nextStepStatusTitle: String {
        switch permission.status {
        case .enabled:
            return "Ready"
        case .missing:
            return "Action"
        case .requesting:
            return "Waiting"
        case .relaunchNeeded:
            return "Relaunch"
        }
    }
}

struct SectionFooterNote: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }
}

struct DangerZoneView<Content: View>: View {
    let title: String
    let message: String?
    @ViewBuilder let content: () -> Content

    init(
        title: String,
        message: String? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        self.message = message
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: "exclamationmark.triangle.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(.red)

            if let message, !message.isEmpty {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            content()
        }
        .padding(10)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.red.opacity(0.22), lineWidth: 1)
        )
    }
}

struct KeycapView: View {
    let tokens: [String]
    let accessibilityLabel: String

    init(binding: KeyboardShortcutBinding) {
        let formatted = KeyboardShortcutKeycapFormatter.format(binding.keycapFormatterBinding)
        self.tokens = Self.tokens(from: formatted)
        self.accessibilityLabel = binding.displayName.isEmpty ? "Not set" : binding.displayName
    }

    init(_ text: String, accessibilityLabel: String? = nil) {
        self.tokens = Self.tokens(from: text)
        self.accessibilityLabel = accessibilityLabel ?? text
    }

    var body: some View {
        HStack(spacing: 3) {
            ForEach(Array(tokens.enumerated()), id: \.offset) { _, token in
                Text(token)
                    .font(.system(.caption, design: .monospaced).weight(.semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 3)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 5))
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .stroke(Color.secondary.opacity(0.28), lineWidth: 1)
                    )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Shortcut \(accessibilityLabel)")
    }

    private static func tokens(from text: String) -> [String] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ["Not set"]
        }

        if trimmed.hasPrefix("Right ") {
            return trimmed.split(separator: " ").map(String.init)
        }

        let modifierSymbols: Set<Character> = ["⌃", "⌥", "⇧", "⌘"]
        var remainder = trimmed[...]
        var tokens: [String] = []

        while let first = remainder.first, modifierSymbols.contains(first) {
            tokens.append(String(first))
            remainder.removeFirst()
        }

        let tail = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
        if !tail.isEmpty {
            tokens.append(String(tail))
        }

        return tokens.isEmpty ? [trimmed] : tokens
    }
}

struct KeyRecorderRow<Recorder: View>: View {
    let command: KeyboardShortcutCommand
    let description: String
    let binding: KeyboardShortcutBinding
    let defaultBinding: KeyboardShortcutBinding
    let isRecording: Bool
    let validationMessage: String?
    let validationState: SettingsVisualState?
    let reset: () -> Void
    @ViewBuilder let recorder: () -> Recorder

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsActionRow(
                title: command.title,
                subtitle: description,
                state: rowState,
                statusTitle: rowStatusTitle
            ) {
                HStack(spacing: 8) {
                    KeycapView(binding: binding)
                    recorder()
                    if binding != defaultBinding {
                        Button {
                            reset()
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .buttonStyle(.bordered)
                        .help("Reset \(command.title)")
                        .accessibilityLabel("Reset shortcut for \(command.title)")
                        .accessibilityHint("Restores \(defaultBinding.displayName).")
                    }
                }
            }

            if let validationMessage {
                Label(validationMessage, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle((validationState ?? .warning).tint)
                    .accessibilityLabel(validationMessage)
            }
        }
    }

    private var rowState: SettingsVisualState? {
        if let validationState {
            return validationState
        }
        return isRecording ? .pending : nil
    }

    private var rowStatusTitle: String? {
        if validationState != nil {
            return "Needs change"
        }
        return isRecording ? "Recording" : nil
    }
}

private extension KeyboardShortcutBinding {
    var keycapFormatterBinding: KeyboardShortcutKeycapFormatter.Binding {
        KeyboardShortcutKeycapFormatter.Binding(
            keyCode: keyCode,
            modifiers: modifiers.keycapFormatterModifiers,
            trigger: trigger.keycapFormatterTrigger
        )
    }
}

private extension KeyboardShortcutTrigger {
    var keycapFormatterTrigger: KeyboardShortcutKeycapFormatter.Binding.Trigger {
        switch self {
        case .keyDown:
            return .keyDown
        case .flagsChanged:
            return .flagsChanged
        }
    }
}

private extension KeyboardShortcutModifiers {
    var keycapFormatterModifiers: KeyboardShortcutKeycapFormatter.Modifiers {
        var result: KeyboardShortcutKeycapFormatter.Modifiers = []
        if contains(.command) { result.insert(.command) }
        if contains(.option) { result.insert(.option) }
        if contains(.control) { result.insert(.control) }
        if contains(.shift) { result.insert(.shift) }
        return result
    }
}
