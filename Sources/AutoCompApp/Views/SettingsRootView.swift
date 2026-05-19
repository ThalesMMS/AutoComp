import AutoCompCore
import SwiftUI

struct SettingsRootView: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        NavigationSplitView {
            List(selection: $controller.selectedSettingsSection) {
                ForEach(SettingsSection.allCases) { section in
                    Label(section.rawValue, systemImage: section.systemImage)
                        .tag(section)
                }
            }
            .listStyle(.sidebar)
        } detail: {
            switch controller.selectedSettingsSection {
            case .permissions:
                PermissionSettingsView()
            case .apps:
                AppCompatibilitySettingsView()
            case .privacy:
                PrivacySettingsView()
            case .shortcuts:
                ShortcutSettingsView()
            case .model:
                ModelSettingsView()
            }
        }
    }
}

struct PermissionSettingsView: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var permissions: PermissionService

    var body: some View {
        Form {
            Section("Required") {
                LabeledContent("Accessibility", value: permissions.accessibilityTrusted ? "Enabled" : "Missing")
                Button("Request Accessibility Permission") {
                    permissions.requestAccessibility()
                }
                Button("Open Privacy & Security") {
                    permissions.openAccessibilitySettings()
                }

                LabeledContent("Input Monitoring", value: permissions.inputMonitoringAllowed ? "Enabled" : "Missing")
                Text(permissions.inputMonitoringStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Request Input Monitoring Permission") {
                    permissions.requestInputMonitoring()
                }
                Button("Open Input Monitoring Settings") {
                    permissions.openInputMonitoringSettings()
                }
            }

            Section("Optional") {
                LabeledContent(
                    "Screen Recording",
                    value: permissions.screenRecordingAllowed ? "Enabled" : (permissions.screenRecordingNeedsRelaunch ? "Relaunch Required" : "Disabled")
                )
                Text(permissions.screenRecordingStatus)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Request Screen Recording Permission") {
                    permissions.requestScreenRecording()
                }
                Button("Open Screen Recording Settings") {
                    permissions.openScreenRecordingSettings()
                }
                if permissions.screenRecordingNeedsRelaunch {
                    Button("Relaunch AutoComp") {
                        controller.relaunch()
                    }
                }
            }

            Section("Runtime identity") {
                LabeledContent("Bundle ID", value: permissions.runtimeBundleID)
                Text(permissions.runtimeExecutablePath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("Permissions")
    }
}

struct AppCompatibilitySettingsView: View {
    @EnvironmentObject private var controller: AppController
    @State private var overrides: [String: Bool] = [:]

    var body: some View {
        List {
            ForEach(controller.compatibilityCatalog.profiles) { profile in
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(profile.displayName)
                            .font(.headline)
                        Text(profile.notes.isEmpty ? profile.status.rawValue : profile.notes)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    Spacer()

                    Text(profile.defaultMode.rawValue)
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Toggle("", isOn: binding(for: profile))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .disabled(profile.status == .unsupported)
                }
                .padding(.vertical, 4)
            }
        }
        .navigationTitle("Apps")
        .onAppear {
            overrides = controller.compatibilitySettings.loadOverrides()
        }
    }

    private func binding(for profile: AppCompatibilityProfile) -> Binding<Bool> {
        Binding {
            overrides[profile.bundleID] ?? profile.enabledByDefault
        } set: { enabled in
            overrides[profile.bundleID] = enabled
            controller.compatibilitySettings.setEnabled(enabled, for: profile.bundleID)
        }
    }
}

struct PrivacySettingsView: View {
    @EnvironmentObject private var controller: AppController
    @State private var settings = PrivacySettings()
    @State private var recordCount = 0

    var body: some View {
        Form {
            Section("Collection") {
                Toggle("Enable optional local input collection", isOn: $settings.collectionEnabled)
                Toggle("Use clipboard as local context", isOn: $settings.clipboardContextEnabled)
                Toggle("Use visible screen text as local context", isOn: $settings.screenContextEnabled)
                Slider(value: $settings.personalizationStrength, in: 0...1) {
                    Text("Personalization strength")
                }
            }

            Section("Local data") {
                LabeledContent("Encrypted records", value: "\(recordCount)")
                Button("Save Privacy Settings") {
                    try? controller.privacySettingsStore.save(settings)
                }
                Button("Delete Local Personalization Data", role: .destructive) {
                    controller.deletePersonalizationData()
                    recordCount = controller.personalizationStore.recordCount()
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("Privacy")
        .onAppear {
            settings = controller.privacySettingsStore.load()
            recordCount = controller.personalizationStore.recordCount()
        }
    }
}

struct ShortcutSettingsView: View {
    var body: some View {
        Form {
            Section("Acceptance") {
                LabeledContent("Accept next word", value: "Tab")
                LabeledContent("Accept full suggestion", value: "Right Shift")
            }

            Section("Terminal") {
                LabeledContent("Force activate", value: "Use the menu bar while focused in Terminal or iTerm")
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("Shortcuts")
    }
}

struct ModelSettingsView: View {
    @EnvironmentObject private var controller: AppController
    @State private var draft = CompletionBackendSettings()

    var body: some View {
        Form {
            Section("Provider") {
                LabeledContent("Backend", value: "Remote OpenAI-compatible")
                TextField("Base URL", text: $draft.remoteBaseURL)
                SecureField("API key", text: $draft.remoteAPIKey)
                TextField("Model", text: $draft.remoteModel)

                Button("Save and Use Backend") {
                    controller.saveCompletionBackendSettings(draft)
                }
            }

            Section("Active remote backend") {
                LabeledContent("Active backend", value: controller.completionBackendSummary)
                Button("Reload Saved Backend") {
                    controller.refreshCompletionBackendSettings()
                }
            }

            Section("Privacy") {
                Text("Autocomplete text is sent to the configured remote OpenAI-compatible endpoint. This build does not include a local completion backend.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("Model")
        .onAppear {
            draft = controller.completionBackendSettings
        }
    }
}
