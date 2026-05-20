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
                ForEach(permissions.permissionPresentations.filter { $0.requirement == .required }) { permission in
                    PermissionSettingsRow(permission: permission, permissions: permissions)
                }
            }

            Section("Optional") {
                ForEach(permissions.permissionPresentations.filter { $0.requirement == .optional }) { permission in
                    PermissionSettingsRow(permission: permission, permissions: permissions)
                    if permission.needsRelaunch {
                        Button("Relaunch AutoComp") {
                            controller.relaunch()
                        }
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

private struct PermissionSettingsRow: View {
    let permission: PermissionPresentation
    @ObservedObject var permissions: PermissionService

    var body: some View {
        LabeledContent(permission.title, value: permission.statusTitle)
        Text("Reason")
            .font(.caption.weight(.medium))
        Text(permission.message)
            .font(.caption)
            .foregroundStyle(.secondary)
        Text("Next step")
            .font(.caption.weight(.medium))
        Text(permission.nextActionTitle)
            .font(.caption)
            .foregroundStyle(.secondary)
        if !permission.isComplete {
            Button(permission.requestButtonTitle) {
                permissions.request(permission.kind)
            }
            Button(permission.openSettingsButtonTitle) {
                permissions.openSettings(for: permission.kind)
            }
        }
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
                Picker("Backend", selection: $draft.engineKind) {
                    ForEach(CompletionEngineKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                TextField("Base URL", text: $draft.remoteBaseURL)
                SecureField("API key", text: $draft.remoteAPIKey)
                TextField("Model", text: $draft.remoteModel)
                Toggle("Fallback to remote if Apple fails", isOn: $draft.fallbackToRemoteOnAppleIntelligenceFailure)

                Button("Save and Use Backend") {
                    controller.saveCompletionBackendSettings(draft)
                }
            }

            Section("Local model") {
                TextField("Model path", text: $draft.localModelPath)
                TextField("Max RAM bytes", text: localMaxRAMBinding)
                Toggle("Fallback to remote if local fails", isOn: $draft.fallbackToRemoteOnLocalFailure)
            }

            Section("Local diagnostics") {
                let diagnostic = draft.localDiagnostic()
                LabeledContent("Runtime", value: diagnostic.runtimeTitle)
                LabeledContent("Model file", value: diagnostic.modelFileTitle)
                LabeledContent("Load state", value: diagnostic.loadStateTitle)
                LabeledContent("Last error", value: diagnostic.lastErrorTitle)
                LabeledContent("Fallback", value: diagnostic.fallbackTitle)
                LabeledContent("Memory limit", value: diagnostic.memoryLimitTitle)
                Text("Local in-process completion is usable only when this build includes the runtime and the model file exists. Apple Intelligence requires FoundationModels on a supported macOS release.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Active backend") {
                LabeledContent("Active backend", value: controller.completionBackendSummary)
                Button("Reload Saved Backend") {
                    controller.refreshCompletionBackendSettings()
                }
            }

            Section("Privacy") {
                Text("Autocomplete text is sent to the selected backend, and to the remote backend only when remote fallback is enabled after a local or Apple failure.")
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

    private var localMaxRAMBinding: Binding<String> {
        Binding {
            String(draft.localMaxRAMBytes)
        } set: { value in
            let digits = value.filter(\.isNumber)
            if let bytes = UInt64(digits) {
                draft.localMaxRAMBytes = bytes
            }
        }
    }
}
