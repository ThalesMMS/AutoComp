import AppKit
import SwiftUI

struct ShortcutSettingsView: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var engine: SuggestionEngine
    @State private var settings = KeyboardShortcutSettings.defaults
    @State private var recordingCommand: KeyboardShortcutCommand?
    @State private var preRecordingBinding: KeyboardShortcutBinding?
    @State private var rejectedShortcut: KeyboardShortcutSettings.ProposedUpdateRejection?

    var body: some View {
        SettingsPaneForm(title: "Shortcuts") {
            Section("Acceptance") {
                shortcutRow(.acceptNextWord)
                shortcutRow(.acceptFullSuggestion)
            }

            Section("Commands") {
                shortcutRow(.manualTrigger)
                shortcutRow(.dismissSuggestion)
                shortcutRow(.toggleAutocomplete)
                SectionFooterNote(text: "Shortcut changes are saved immediately and stay fail-open outside active AutoComp commands.")
            }

            if engine.isMultiSuggestionEnabled {
                Section("Multi-suggestion") {
                    shortcutRow(.selectPreviousSuggestion)
                    shortcutRow(.selectNextSuggestion)
                    SectionFooterNote(text: "These shortcuts are used only while the multi-suggestion popup is visible.")
                }
            }

            Section("Reset") {
                Button("Restore All Defaults") {
                    restoreAllDefaults()
                }
                .disabled(settings == .defaults)
            }
        }
        .onAppear {
            settings = controller.shortcutSettingsStore.load()
        }
    }

    private func shortcutRow(_ command: KeyboardShortcutCommand) -> some View {
        KeyRecorderRow(
            command: command,
            description: command.settingsDescription,
            binding: settings[command],
            defaultBinding: KeyboardShortcutSettings.defaults[command],
            isRecording: recordingCommand == command,
            validationMessage: validationMessage(for: command),
            validationState: validationMessage(for: command) == nil ? nil : .error,
            reset: {
                resetShortcut(command)
            }
        ) {
            ShortcutRecorderButton(
                command: command,
                binding: settings[command],
                isRecording: recordingCommand == command,
                startRecording: {
                    startRecording(command)
                },
                record: { binding in
                    recordShortcut(binding, for: command)
                },
                cancel: {
                    cancelRecording()
                }
            )
        }
    }

    private func startRecording(_ command: KeyboardShortcutCommand) {
        if let recordingCommand, let preRecordingBinding {
            settings[recordingCommand] = preRecordingBinding
        }

        if rejectedShortcut?.command == command {
            rejectedShortcut = nil
        }
        preRecordingBinding = settings[command]
        recordingCommand = command
    }

    private func recordShortcut(_ binding: KeyboardShortcutBinding, for command: KeyboardShortcutCommand) -> Bool {
        switch settings.proposingUpdate(command: command, binding: binding) {
        case .success(let updatedSettings):
            settings = updatedSettings
            rejectedShortcut = nil
            recordingCommand = nil
            preRecordingBinding = nil
            controller.saveKeyboardShortcutSettings(settings)
            announceShortcutUpdate("Saved shortcut")
            return true

        case .failure(let rejection):
            rejectedShortcut = rejection
            recordingCommand = nil
            preRecordingBinding = nil
            announceShortcutUpdate(validationMessage(for: rejection))
            return false
        }
    }

    private func cancelRecording() {
        if let recordingCommand, let preRecordingBinding {
            settings[recordingCommand] = preRecordingBinding
        }
        recordingCommand = nil
        preRecordingBinding = nil
    }

    private func resetShortcut(_ command: KeyboardShortcutCommand) {
        settings[command] = KeyboardShortcutSettings.defaults[command]
        if rejectedShortcut?.command == command {
            rejectedShortcut = nil
        }
        recordingCommand = nil
        preRecordingBinding = nil
        controller.saveKeyboardShortcutSettings(settings)
        announceShortcutUpdate("Shortcut reset")
    }

    private func restoreAllDefaults() {
        settings = .defaults
        rejectedShortcut = nil
        recordingCommand = nil
        preRecordingBinding = nil
        controller.saveKeyboardShortcutSettings(settings)
        announceShortcutUpdate("All shortcuts restored")
    }

    private func validationMessage(for command: KeyboardShortcutCommand) -> String? {
        guard let rejectedShortcut,
              rejectedShortcut.command == command else {
            return nil
        }
        return validationMessage(for: rejectedShortcut)
    }

    private func validationMessage(for rejection: KeyboardShortcutSettings.ProposedUpdateRejection) -> String {
        switch rejection.reason {
        case .reservedShortcut:
            return "\(rejection.binding.displayName) is reserved by macOS or common app commands. Choose another shortcut."
        case .duplicateShortcut(let conflictsWith):
            return "\(rejection.binding.displayName) already belongs to \(conflictsWith.title). Choose another shortcut or reset one of them."
        }
    }

    private func announceShortcutUpdate(_ message: String) {
        let announcement = NSAccessibility.Notification.announcementRequested
        let userInfo: [NSAccessibility.NotificationUserInfoKey: Any] = [
            .announcement: message,
            .priority: NSAccessibilityPriorityLevel.high.rawValue
        ]
        NSAccessibility.post(element: NSApp as Any, notification: announcement, userInfo: userInfo)
    }
}

private struct ShortcutRecorderButton: View {
    let command: KeyboardShortcutCommand
    let binding: KeyboardShortcutBinding
    let isRecording: Bool
    let startRecording: () -> Void
    let record: (KeyboardShortcutBinding) -> Bool
    let cancel: () -> Void

    @State private var inlineConfirmationText: String?
    @State private var pendingDismissTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Button(isRecording ? "Recording..." : "Change") {
                startRecording()
            }
            .buttonStyle(.bordered)
            .accessibilityIdentifier("ShortcutRecorderButton.\(command.rawValue)")
            .accessibilityLabel(command.title)
            .accessibilityValue(isRecording ? "Recording" : (binding.displayName.isEmpty ? "Not set" : binding.displayName))
            .accessibilityHint(
                isRecording
                    ? "Type a key combination. Press Escape to cancel."
                    : "Press to record a new shortcut. The current shortcut is shown in the keycap."
            )
            .background(
                ShortcutCaptureView(
                    isActive: isRecording,
                    record: { binding in
                        let didSave = record(binding)
                        if didSave {
                            showInlineConfirmation("Saved")
                        }
                        return didSave
                    },
                    cancel: cancel
                )
                .frame(width: 0, height: 0)
            )

            if isRecording {
                Text("Press Esc to cancel")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    // Keep the guidance accessible even if VoiceOver focus remains on the button.
                    .accessibilityLabel("Press Escape to cancel")
            } else if let inlineConfirmationText {
                Text(inlineConfirmationText)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    // Prevent layout jumps by reserving roughly the same height as the guidance row.
                    .transition(.opacity)
                    .accessibilityIdentifier("ShortcutRecorderConfirmationText.\(command.rawValue)")
                    .accessibilityLabel(inlineConfirmationText)
            }
        }
        .onChange(of: isRecording) { _, newValue in
            if newValue {
                clearInlineConfirmation()
            }
        }
        .onDisappear {
            pendingDismissTask?.cancel()
        }
    }

    private func showInlineConfirmation(_ text: String) {
        inlineConfirmationText = text

        pendingDismissTask?.cancel()
        pendingDismissTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            withAnimation(.easeOut(duration: 0.15)) {
                inlineConfirmationText = nil
            }
        }
    }

    private func clearInlineConfirmation() {
        pendingDismissTask?.cancel()
        pendingDismissTask = nil
        inlineConfirmationText = nil
    }
}

private struct ShortcutCaptureView: NSViewRepresentable {
    let isActive: Bool
    let record: (KeyboardShortcutBinding) -> Bool
    let cancel: () -> Void

    func makeNSView(context: Context) -> ShortcutCaptureNSView {
        let view = ShortcutCaptureNSView()
        view.record = record
        view.cancel = cancel
        return view
    }

    func updateNSView(_ nsView: ShortcutCaptureNSView, context: Context) {
        nsView.record = record
        nsView.cancel = cancel
        nsView.isActive = isActive
        if isActive {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }
}

private final class ShortcutCaptureNSView: NSView {
    var isActive = false
    var record: ((KeyboardShortcutBinding) -> Bool)?
    var cancel: (() -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        guard isActive else {
            super.keyDown(with: event)
            return
        }

        let modifiers = KeyboardShortcutModifiers(nsEventFlags: event.modifierFlags)
        if event.keyCode == CapturedInputEventAdapter.escapeKeyCode,
           modifiers.isEmpty {
            cancel?()
            return
        }

        _ = record?(KeyboardShortcutBinding(event: event, trigger: .keyDown))
    }

    override func mouseDown(with event: NSEvent) {
        // Clicking elsewhere in the window should cancel recording so we don't
        // leave the recorder in a stuck state.
        if isActive {
            cancel?()
            return
        }
        super.mouseDown(with: event)
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if isActive {
            cancel?()
        }
        return resigned
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil, isActive {
            cancel?()
        }
    }

    override func viewWillMove(toWindow newWindow: NSWindow?) {
        super.viewWillMove(toWindow: newWindow)

        // Losing the hosting window (settings closed) should cancel any in-flight recording.
        if newWindow == nil, isActive {
            cancel?()
        }
    }

    override func flagsChanged(with event: NSEvent) {
        guard isActive else {
            return
        }

        let modifiers = KeyboardShortcutModifiers(nsEventFlags: event.modifierFlags)
        guard !modifiers.isEmpty else {
            return
        }

        _ = record?(KeyboardShortcutBinding(event: event, trigger: .flagsChanged))
    }
}
