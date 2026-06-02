import AutoCompCore
import SwiftUI

struct GeneralSettingsView: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var permissions: PermissionService
    @EnvironmentObject private var engine: SuggestionEngine
    @State private var emojiPreferences = EmojiVariantPreferences()

    var body: some View {
        SettingsPaneForm(title: "General") {
            Section("Status") {
                SettingsActionRow(
                    title: "AutoComp",
                    state: engine.isAutocompleteEnabled ? .ok : .disabled,
                    statusTitle: engine.isAutocompleteEnabled ? "Enabled" : "Disabled"
                )
                SettingsActionRow(
                    title: "Accessibility",
                    state: permissions.accessibilityTrusted ? .ok : .error,
                    statusTitle: permissions.accessibilityTrusted ? "Ready" : "Needs setup"
                )
                SettingsActionRow(
                    title: "Backend",
                    subtitle: controller.completionBackendSummary,
                    state: SettingsVisualState.backend(engine.backendStatusSummary.state),
                    statusTitle: engine.backendStatusSummary.title
                )
                SectionFooterNote(text: engine.statusMessage)
            }

            Section("Autocomplete") {
                Toggle("Enable AutoComp", isOn: autocompleteEnabledBinding)
                SectionFooterNote(text: "Turn off global autocomplete without changing app-specific compatibility or model settings.")
            }

            Section("Emoji picker") {
                Toggle("Enable inline emoji picker", isOn: emojiPickerEnabledBinding)
                Picker("Skin tone", selection: emojiSkinToneBinding) {
                    ForEach(EmojiSkinTone.allCases) { tone in
                        Text(tone.displayName).tag(tone)
                    }
                }
                Picker("Gender variant", selection: emojiGenderBinding) {
                    ForEach(EmojiGenderPresentation.allCases) { presentation in
                        Text(presentation.displayName).tag(presentation)
                    }
                }
                LabeledContent("Accept key", value: controller.emojiPickerAcceptKeyLabel)
                SectionFooterNote(text: "Scoped keyboard handling keeps the picker separate from autocomplete.")
            }

            Section("Quick actions") {
                Button("Open Setup") {
                    controller.selectedSettingsSection = .setup
                }
                Button("Open Health") {
                    controller.selectedSettingsSection = .health
                }
                Button("Run Onboarding Again") {
                    controller.showOnboardingWindow()
                }
            }
        }
        .onAppear {
            emojiPreferences = controller.emojiVariantPreferences()
        }
    }

    private var autocompleteEnabledBinding: Binding<Bool> {
        Binding {
            engine.isAutocompleteEnabled
        } set: { enabled in
            controller.setAutocompleteEnabled(enabled)
        }
    }

    private var emojiPickerEnabledBinding: Binding<Bool> {
        Binding {
            emojiPreferences.isEnabled
        } set: { enabled in
            var updated = emojiPreferences
            updated.isEnabled = enabled
            saveEmojiPreferences(updated)
        }
    }

    private var emojiSkinToneBinding: Binding<EmojiSkinTone> {
        Binding {
            emojiPreferences.skinTone
        } set: { tone in
            var updated = emojiPreferences
            updated.skinTone = tone
            saveEmojiPreferences(updated)
        }
    }

    private var emojiGenderBinding: Binding<EmojiGenderPresentation> {
        Binding {
            emojiPreferences.genderPresentation
        } set: { presentation in
            var updated = emojiPreferences
            updated.genderPresentation = presentation
            saveEmojiPreferences(updated)
        }
    }

    private func saveEmojiPreferences(_ preferences: EmojiVariantPreferences) {
        emojiPreferences = preferences
        controller.saveEmojiVariantPreferences(preferences)
    }
}
