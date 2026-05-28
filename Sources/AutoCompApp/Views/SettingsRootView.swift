import AutoCompCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct SettingsRootView: View {
    private let sidebarWidth: CGFloat = 210

    @EnvironmentObject private var controller: AppController

    var body: some View {
        HStack(spacing: 0) {
            List(selection: $controller.selectedSettingsSection) {
                ForEach(SettingsSection.allCases) { section in
                    Label(section.rawValue, systemImage: section.systemImage)
                        .tag(section)
                }
            }
            .listStyle(.sidebar)
            .frame(width: sidebarWidth)

            Divider()

            selectedSectionView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 880, minHeight: 560)
    }

    @ViewBuilder
    private var selectedSectionView: some View {
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

            Section("Overlay recovery") {
                OverlayRecoveryRecommendationView(advisor: controller.overlayRecoveryAdvisor)
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
        LabeledContent("Requirement", value: permission.requirementDetail)
        LabeledContent("Settings", value: permission.settingsLocation)
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

private struct OverlayRecoveryRecommendationView: View {
    @ObservedObject var advisor: OverlayRecoveryAdvisor

    var body: some View {
        LabeledContent("Safe simple mode", value: advisor.safeModeStatusTitle)
        LabeledContent("Advanced overlay failures", value: "\(advisor.advancedOverlayFailureCount)")

        if advisor.shouldRecommendSafeOverlayMode {
            Label("Safe simple mode recommended", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
        }

        Text(advisor.recommendationMessage)
            .font(.caption)
            .foregroundStyle(.secondary)

        Button("Clear Overlay Failure Count") {
            advisor.resetAdvancedOverlayFailures()
        }
        .disabled(advisor.advancedOverlayFailureCount == 0)
    }
}

struct AppCompatibilitySettingsView: View {
    @EnvironmentObject private var controller: AppController
    @State private var overrides: [String: CompatibilityOverrideMode] = [:]
    @State private var installedApps: [InstalledApplication] = []
    @State private var searchText = ""
    @State private var domainText = ""
    @State private var newDomainMode: CompatibilityOverrideMode = .manualOnly
    @State private var isScanningApps = false

    private var filteredApps: [InstalledApplication] {
        InstalledApplicationFilter.filter(installedApps, matching: searchText)
    }

    private var domainRows: [DomainOverrideRow] {
        overrides.compactMap { key, mode -> DomainOverrideRow? in
            guard key.hasPrefix("domain:") else {
                return nil
            }
            return DomainOverrideRow(
                domain: String(key.dropFirst("domain:".count)),
                mode: mode
            )
        }
        .sorted { $0.domain < $1.domain }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                TextField("Search apps", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                Button {
                    reloadInstalledApps()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh installed apps")

                Button("Restore Defaults") {
                    restoreDefaults()
                }
                .disabled(overrides.isEmpty)
            }
            .padding()

            List {
                Section("Domain rules") {
                    domainRuleCreator
                    if domainRows.isEmpty {
                        Text("No domain rules.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(domainRows) { row in
                            domainRuleRow(row)
                        }
                    }
                }

                Section("Installed apps") {
                    if isScanningApps {
                        ProgressView("Scanning installed apps")
                    } else if filteredApps.isEmpty {
                        Text(searchText.isEmpty ? "No installed apps found." : "No apps match the search.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(filteredApps) { app in
                            appRow(app)
                        }
                    }
                }
            }
        }
        .navigationTitle("Apps")
        .onAppear {
            overrides = controller.compatibilitySettings.loadModeOverrides()
            if installedApps.isEmpty {
                reloadInstalledApps()
            }
        }
    }

    private var domainRuleCreator: some View {
        HStack(spacing: 8) {
            TextField("Domain or path", text: $domainText)
                .textFieldStyle(.roundedBorder)

            Picker("Mode", selection: $newDomainMode) {
                ForEach(CompatibilityOverrideMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(width: 130)

            Button {
                addDomainRule()
            } label: {
                Image(systemName: "plus")
            }
            .help("Add domain rule")
            .disabled(CompatibilityCatalog.normalizedDomain(domainText).isEmpty)
        }
    }

    private func domainRuleRow(_ row: DomainOverrideRow) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "globe")
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(row.domain)
                    .font(.headline)
                Text("Domain override")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("Mode", selection: domainModeBinding(for: row.domain)) {
                ForEach(CompatibilityOverrideMode.allCases) { mode in
                    Text(mode.title).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 130)

            Button {
                removeDomainRule(row.domain)
            } label: {
                Image(systemName: "trash")
            }
            .help("Remove domain rule")
        }
        .padding(.vertical, 4)
    }

    private func appRow(_ app: InstalledApplication) -> some View {
        let profile = controller.compatibilityCatalog.profile(for: app.bundleID)
        return HStack(spacing: 12) {
            Image(nsImage: app.icon)
                .resizable()
                .frame(width: 32, height: 32)

            VStack(alignment: .leading, spacing: 3) {
                Text(app.displayName)
                    .font(.headline)
                Text(app.bundleID)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                if !profile.notes.isEmpty {
                    Text(profile.notes)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer()

            Text(defaultModeTitle(for: profile))
                .font(.caption)
                .foregroundStyle(.secondary)

            Picker("Mode", selection: modeBinding(for: app.bundleID)) {
                Text("Default").tag(CompatibilityOverrideMode?.none)
                ForEach(CompatibilityOverrideMode.allCases) { mode in
                    Text(mode.title).tag(Optional(mode))
                }
            }
            .pickerStyle(.menu)
            .frame(width: 130)

            Button {
                setMode(nil, for: app.bundleID)
            } label: {
                Image(systemName: "arrow.uturn.backward")
            }
            .help("Remove app override")
            .disabled(overrides[app.bundleID] == nil)
        }
        .padding(.vertical, 4)
    }

    private func domainModeBinding(for domain: String) -> Binding<CompatibilityOverrideMode> {
        Binding {
            overrides[CompatibilityCatalog.overrideKey(forDomain: domain)] ?? .manualOnly
        } set: { mode in
            setDomainMode(mode, for: domain)
        }
    }

    private func modeBinding(for bundleID: String) -> Binding<CompatibilityOverrideMode?> {
        Binding {
            overrides[bundleID]
        } set: { mode in
            setMode(mode, for: bundleID)
        }
    }

    private func addDomainRule() {
        let domain = CompatibilityCatalog.normalizedDomain(domainText)
        guard !domain.isEmpty else {
            return
        }
        setDomainMode(newDomainMode, for: domain)
        domainText = ""
    }

    private func setDomainMode(_ mode: CompatibilityOverrideMode, for domain: String) {
        let key = CompatibilityCatalog.overrideKey(forDomain: domain)
        overrides[key] = mode
        controller.compatibilitySettings.setMode(mode, forDomain: domain)
    }

    private func removeDomainRule(_ domain: String) {
        let key = CompatibilityCatalog.overrideKey(forDomain: domain)
        overrides.removeValue(forKey: key)
        controller.compatibilitySettings.setMode(nil, forDomain: domain)
    }

    private func setMode(_ mode: CompatibilityOverrideMode?, for bundleID: String) {
        if let mode {
            overrides[bundleID] = mode
        } else {
            overrides.removeValue(forKey: bundleID)
        }
        controller.compatibilitySettings.setMode(mode, for: bundleID)
    }

    private func restoreDefaults() {
        overrides = [:]
        controller.compatibilitySettings.resetOverrides()
    }

    private func defaultModeTitle(for profile: AppCompatibilityProfile) -> String {
        "Default: \(profile.defaultActivationMode.title)"
    }

    private func reloadInstalledApps() {
        isScanningApps = true
        installedApps = InstalledApplicationScanner().scan()
        isScanningApps = false
    }

    private struct DomainOverrideRow: Identifiable {
        let domain: String
        let mode: CompatibilityOverrideMode

        var id: String { domain }
    }
}

struct PrivacySettingsView: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var engine: SuggestionEngine
    @State private var settings = PrivacySettings()
    @State private var debugOptions = AutoCompDebugOptions()
    @State private var recordCount = 0
    @State private var debugArtifactCount = 0
    @State private var debugArtifactMessage: String?
    @State private var settingsTransferMessage: String?
    @State private var pendingSettingsImportPreview: RedactedSettingsImportPreview?
    @State private var draftWritingRule = ""
    @State private var draftPrivacyDomain = ""
    @State private var draftDomainCollectionAllowed = false
    @State private var privacyDataMessage: String?

    var body: some View {
        Form {
            Section("Collection") {
                Toggle("Enable optional local input collection", isOn: privacyBinding(\.collectionEnabled))
                Toggle("Use clipboard as local context", isOn: privacyBinding(\.clipboardContextEnabled))
                Toggle("Use visible screen text as local context", isOn: privacyBinding(\.screenContextEnabled))
                Slider(value: personalizationStrengthBinding, in: 0...1) {
                    Text("Personalization strength")
                }
            }

            Section("Source policy") {
                privacyPolicyTable(rows: privacyPolicyRows)
            }

            Section("Domain collection rules") {
                Text("Browser domains use the active tab host. The most specific saved rule applies before app-level collection rules.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack {
                    TextField("Domain", text: $draftPrivacyDomain)
                        .textFieldStyle(.roundedBorder)
                    Picker("Rule", selection: $draftDomainCollectionAllowed) {
                        Text("Disable collection").tag(false)
                        Text("Allow collection").tag(true)
                    }
                    Button("Add") {
                        addPrivacyDomainRule()
                    }
                    .disabled(normalizedDraftPrivacyDomain.isEmpty)
                }

                if domainPrivacyRows.isEmpty {
                    Text("No domain collection rules.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(domainPrivacyRows) { row in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(row.domain)
                                Text(row.allowed ? "Collection allowed" : "Collection disabled")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Remove") {
                                removePrivacyDomainRule(row.domain)
                            }
                        }
                    }
                }
            }

            Section("Writing preferences") {
                Toggle("Use writing preferences", isOn: writingPreferencesEnabledBinding)

                if settings.writingPreferences.enabled {
                    if !settings.writingPreferences.rules.isEmpty {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 180), alignment: .leading)],
                            alignment: .leading,
                            spacing: 8
                        ) {
                            ForEach(settings.writingPreferences.rules, id: \.self) { rule in
                                writingRuleChip(rule)
                            }
                        }
                    }

                    HStack {
                        TextField("Add writing rule", text: $draftWritingRule)
                            .onSubmit(commitDraftWritingRules)
                            .onChange(of: draftWritingRule) { _, value in
                                guard value.contains(",") else {
                                    return
                                }
                                commitDraftWritingRules()
                            }
                        Button("Add") {
                            commitDraftWritingRules()
                        }
                        .disabled(!draftHasAddableWritingRule)
                    }

                    LabeledContent(
                        "Rules",
                        value: "\(settings.writingPreferences.rules.count)/\(WritingPreferences.maxRules)"
                    )

                    if let promptPreview = settings.writingPreferences.promptPreview,
                       debugOptions.allowsSensitivePromptPreview {
                        Text("Prompt preview")
                            .font(.caption.weight(.medium))
                        Text(promptPreview)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    } else if settings.writingPreferences.promptPreview != nil {
                        Text("Prompt preview hidden until local debug opt-in is enabled.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 160), alignment: .leading)],
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ForEach(WritingPreferences.suggestedRules, id: \.self) { rule in
                            Button(rule) {
                                addWritingRule(rule)
                            }
                            .disabled(!canAddWritingRule(rule))
                        }
                    }
                }
            }

            Section("Completion backend") {
                let backendSettings = controller.completionBackendSettings
                LabeledContent("Active engine", value: backendSettings.engineKind.displayName)
                LabeledContent("Request destination", value: backendSettings.requestDestinationTitle)
                LabeledContent("Data leaves this Mac", value: backendSettings.dataLeavesDeviceTitle)
                LabeledContent("Remote fallback", value: backendSettings.remoteFallbackTitle)
                LabeledContent("Last backend used", value: engine.diagnostics.backend.lastUsedTitle)
                Text("Privacy controls limit optional local context. The selected completion backend still receives the autocomplete request shown here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Local metrics") {
                Toggle("Keep local productivity counters", isOn: privacyBinding(\.productivityMetricsEnabled))
                ProductivityMetricsSettingsSummary(
                    metrics: controller.productivityMetricsStore,
                    reset: {
                        controller.resetProductivityMetrics()
                    }
                )
            }

            Section("Local data") {
                LabeledContent("Encrypted records", value: "\(recordCount)")
                Button("Delete Local Personalization Data", role: .destructive) {
                    controller.deletePersonalizationData()
                    settings = controller.privacySettingsStore.load()
                    recordCount = controller.personalizationStore.recordCount()
                }
                Button("Delete All Local Privacy Data", role: .destructive) {
                    deleteAllLocalPrivacyData()
                }
                if let privacyDataMessage {
                    Text(privacyDataMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Debug") {
                Toggle("Enable local debug artifacts and prompt previews", isOn: debugOptInBinding)
                Text("When enabled, AutoComp may save prompts, OCR, clipboard context, or typed text to local debug artifacts. Leave this off unless actively debugging.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                LabeledContent("Debug artifacts", value: "\(debugArtifactCount)")
                LabeledContent("Location", value: controller.debugArtifactDirectoryPath)
                Button("Export Debug Logs...") {
                    exportDebugLogs()
                }
                Button("Export Redacted Settings...") {
                    exportRedactedSettings()
                }
                Button("Import Redacted Settings...") {
                    importRedactedSettings()
                }
                if let pendingSettingsImportPreview {
                    redactedSettingsImportPreview(pendingSettingsImportPreview)
                }
                if let settingsTransferMessage {
                    Text(settingsTransferMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Button("Delete Debug Artifacts", role: .destructive) {
                    deleteDebugArtifacts()
                }
                if let debugArtifactMessage {
                    Text(debugArtifactMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("Privacy")
        .onAppear {
            settings = controller.privacySettingsStore.load()
            recordCount = controller.personalizationStore.recordCount()
            reloadDebugState()
        }
    }

    private var privacyPolicyRows: [PrivacyPolicyRow] {
        [
            PrivacyPolicyRow(
                source: "AX text",
                defaultState: "On while autocomplete is enabled",
                purpose: "Completion request",
                remoteBackend: remoteBackendExposure(sourceEnabled: true),
                turnOff: "Disable autocomplete or disable the app/domain in compatibility settings",
                retention: "Not retained"
            ),
            PrivacyPolicyRow(
                source: "Clipboard",
                defaultState: "Off",
                purpose: "Optional context",
                remoteBackend: remoteBackendExposure(sourceEnabled: settings.clipboardContextEnabled),
                turnOff: "Privacy > Use clipboard as local context",
                retention: "Not retained"
            ),
            PrivacyPolicyRow(
                source: "Screen OCR",
                defaultState: "Off",
                purpose: "Visual context and geometry fallback",
                remoteBackend: remoteBackendExposure(sourceEnabled: settings.screenContextEnabled),
                turnOff: "Privacy > Use visible screen text as local context",
                retention: "Not retained"
            ),
            PrivacyPolicyRow(
                source: "Debug logs",
                defaultState: "Sensitive content off",
                purpose: "Diagnostics",
                remoteBackend: "No",
                turnOff: "Privacy > Debug",
                retention: "Sensitive artifacts stay local until deleted"
            ),
            PrivacyPolicyRow(
                source: "Productivity metrics",
                defaultState: "On",
                purpose: "Local value feedback",
                remoteBackend: "No",
                turnOff: "Privacy > Keep local productivity counters",
                retention: "Local counters until reset"
            )
        ]
    }

    private var domainPrivacyRows: [PrivacyDomainRuleRow] {
        settings.perDomainRules
            .map { domain, allowed in
                PrivacyDomainRuleRow(domain: domain, allowed: allowed)
            }
            .sorted { $0.domain < $1.domain }
    }

    private var normalizedDraftPrivacyDomain: String {
        PrivacySettings.normalizedDomain(draftPrivacyDomain)
    }

    private func remoteBackendExposure(sourceEnabled: Bool) -> String {
        controller.completionBackendSettings.remoteBackendExposureTitle(sourceEnabled: sourceEnabled)
    }

    private func privacyPolicyTable(rows: [PrivacyPolicyRow]) -> some View {
        ScrollView(.horizontal) {
            Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                GridRow {
                    privacyPolicyHeader("Source")
                    privacyPolicyHeader("Default")
                    privacyPolicyHeader("Purpose")
                    privacyPolicyHeader("Remote backend")
                    privacyPolicyHeader("How to turn off")
                    privacyPolicyHeader("Retention")
                }

                ForEach(rows) { row in
                    GridRow {
                        privacyPolicyCell(row.source).fontWeight(.medium)
                        privacyPolicyCell(row.defaultState)
                        privacyPolicyCell(row.purpose)
                        privacyPolicyCell(row.remoteBackend)
                        privacyPolicyCell(row.turnOff)
                        privacyPolicyCell(row.retention)
                    }
                }
            }
            .font(.caption)
        }
    }

    private func privacyPolicyHeader(_ title: String) -> Text {
        Text(title)
            .font(.caption.weight(.semibold))
    }

    private func privacyPolicyCell(_ value: String) -> Text {
        Text(value)
    }

    private var draftHasAddableWritingRule: Bool {
        draftWritingRule
            .split(separator: ",", omittingEmptySubsequences: false)
            .map(String.init)
            .contains(where: canAddWritingRule)
    }

    private var writingPreferencesEnabledBinding: Binding<Bool> {
        Binding {
            settings.writingPreferences.enabled
        } set: { enabled in
            var updatedSettings = settings
            updatedSettings.writingPreferences.enabled = enabled
            save(updatedSettings)
        }
    }

    private func privacyBinding(_ keyPath: WritableKeyPath<PrivacySettings, Bool>) -> Binding<Bool> {
        Binding {
            settings[keyPath: keyPath]
        } set: { value in
            var updatedSettings = settings
            updatedSettings[keyPath: keyPath] = value
            save(updatedSettings)
        }
    }

    private var personalizationStrengthBinding: Binding<Double> {
        Binding {
            settings.personalizationStrength
        } set: { value in
            var updatedSettings = settings
            updatedSettings.personalizationStrength = value
            save(updatedSettings)
        }
    }

    private var debugOptInBinding: Binding<Bool> {
        Binding {
            debugOptions.localDebugOptIn
        } set: { value in
            debugOptions.localDebugOptIn = value
            controller.saveDebugOptions(debugOptions)
            debugArtifactMessage = value
                ? "Sensitive prompt previews and local artifacts are enabled."
                : "Sensitive prompt previews and local artifacts are disabled."
            debugArtifactCount = controller.debugArtifactCount()
        }
    }

    private func addPrivacyDomainRule() {
        let domain = normalizedDraftPrivacyDomain
        guard !domain.isEmpty else {
            return
        }

        var updatedSettings = settings
        updatedSettings.perDomainRules[domain] = draftDomainCollectionAllowed
        save(updatedSettings)
        draftPrivacyDomain = ""
    }

    private func removePrivacyDomainRule(_ domain: String) {
        var updatedSettings = settings
        updatedSettings.perDomainRules.removeValue(forKey: domain)
        save(updatedSettings)
    }

    private func save(_ updatedSettings: PrivacySettings) {
        settings = updatedSettings
        controller.savePrivacySettings(updatedSettings)
    }

    private func reloadDebugState() {
        debugOptions = controller.debugOptions()
        debugArtifactCount = controller.debugArtifactCount()
    }

    private func deleteDebugArtifacts() {
        do {
            try controller.deleteDebugArtifacts()
            debugArtifactCount = controller.debugArtifactCount()
            debugArtifactMessage = "Debug artifacts deleted."
        } catch {
            debugArtifactMessage = "Unable to delete debug artifacts: \(error.localizedDescription)"
        }
    }

    private func exportDebugLogs() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Export"
        panel.message = "Choose where to save the local debug log export."

        guard panel.runModal() == .OK, let directory = panel.url else {
            return
        }

        do {
            let exportURL = try controller.exportDebugLogs(to: directory)
            debugArtifactCount = controller.debugArtifactCount()
            debugArtifactMessage = "Debug logs exported to \(exportURL.path)."
        } catch {
            debugArtifactMessage = "Unable to export debug logs: \(error.localizedDescription)"
        }
    }

    private func exportRedactedSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = controller.redactedSettingsExportFilename()
        panel.prompt = "Export"
        panel.message = "Choose where to save the redacted settings export."

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            try controller.exportRedactedSettings(to: url)
            pendingSettingsImportPreview = nil
            settingsTransferMessage = "Redacted settings exported to \(url.path)."
        } catch {
            settingsTransferMessage = "Unable to export redacted settings: \(error.localizedDescription)"
        }
    }

    private func importRedactedSettings() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.json]
        panel.prompt = "Import"
        panel.message = "Choose a redacted settings export."

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        do {
            let data = try Data(contentsOf: url)
            pendingSettingsImportPreview = try controller.redactedSettingsImportPreview(from: data)
            settingsTransferMessage = "Review the import preview before applying."
        } catch {
            pendingSettingsImportPreview = nil
            settingsTransferMessage = "Unable to import redacted settings: \(error.localizedDescription)"
        }
    }

    private func applyRedactedSettingsImport(_ preview: RedactedSettingsImportPreview) {
        do {
            try controller.applyRedactedSettingsImport(preview)
            settings = controller.privacySettingsStore.load()
            pendingSettingsImportPreview = nil
            settingsTransferMessage = "Redacted settings imported."
        } catch {
            settingsTransferMessage = "Unable to apply redacted settings: \(error.localizedDescription)"
        }
    }

    private func redactedSettingsImportPreview(_ preview: RedactedSettingsImportPreview) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Import preview")
                .font(.caption.weight(.medium))
            Text(preview.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
            ForEach(preview.rows) { row in
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.caption.weight(.medium))
                    Text("Current: \(row.currentValue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("Import: \(row.importedValue)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(preview.warnings, id: \.self) { warning in
                Text(warning)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Button("Apply Import") {
                    applyRedactedSettingsImport(preview)
                }
                Button("Cancel Import", role: .cancel) {
                    pendingSettingsImportPreview = nil
                    settingsTransferMessage = "Redacted settings import canceled."
                }
            }
        }
    }

    private func deleteAllLocalPrivacyData() {
        do {
            try controller.deleteAllLocalPrivacyData()
            settings = controller.privacySettingsStore.load()
            recordCount = controller.personalizationStore.recordCount()
            reloadDebugState()
            debugArtifactMessage = nil
            privacyDataMessage = "Personalization, writing preferences, productivity metrics, and debug artifacts deleted."
        } catch {
            recordCount = controller.personalizationStore.recordCount()
            reloadDebugState()
            privacyDataMessage = "Unable to delete all local privacy data: \(error.localizedDescription)"
        }
    }

    private func commitDraftWritingRules() {
        let rawRules = draftWritingRule
            .split(separator: ",", omittingEmptySubsequences: false)
            .map(String.init)

        var updatedPreferences = settings.writingPreferences
        for rule in rawRules {
            updatedPreferences = updatedPreferences.adding(rule)
        }

        var updatedSettings = settings
        updatedSettings.writingPreferences = updatedPreferences
        save(updatedSettings)
        draftWritingRule = ""
    }

    private func addWritingRule(_ rule: String) {
        var updatedSettings = settings
        updatedSettings.writingPreferences = updatedSettings.writingPreferences.adding(rule)
        save(updatedSettings)
    }

    private func removeWritingRule(_ rule: String) {
        var updatedSettings = settings
        updatedSettings.writingPreferences = updatedSettings.writingPreferences.removing(rule)
        save(updatedSettings)
    }

    private func canAddWritingRule(_ rule: String) -> Bool {
        let normalized = WritingPreferences.normalizedRule(rule)
        guard !normalized.isEmpty,
              settings.writingPreferences.rules.count < WritingPreferences.maxRules else {
            return false
        }

        return !settings.writingPreferences.rules
            .map { WritingPreferences.normalizedRule($0).lowercased() }
            .contains(normalized.lowercased())
    }

    private func writingRuleChip(_ rule: String) -> some View {
        HStack(spacing: 6) {
            Text(rule)
                .lineLimit(1)
                .truncationMode(.tail)
            Button {
                removeWritingRule(rule)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove writing rule")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(.quaternary, in: Capsule())
    }

    private struct PrivacyPolicyRow: Identifiable {
        let source: String
        let defaultState: String
        let purpose: String
        let remoteBackend: String
        let turnOff: String
        let retention: String

        var id: String { source }
    }

    private struct PrivacyDomainRuleRow: Identifiable {
        let domain: String
        let allowed: Bool

        var id: String { domain }
    }
}

private struct ProductivityMetricsSettingsSummary: View {
    @ObservedObject var metrics: LocalProductivityMetricsStore
    let reset: () -> Void

    var body: some View {
        let snapshot = metrics.snapshot

        LabeledContent("Status", value: snapshot.isEnabled ? "On" : "Off")
        LabeledContent("Words today", value: "\(snapshot.wordsAcceptedToday)")
        LabeledContent("Words total", value: "\(snapshot.wordsAcceptedTotal)")
        LabeledContent("Suggestions accepted", value: "\(snapshot.suggestionsAccepted)")
        LabeledContent("Suggestions dismissed", value: "\(snapshot.suggestionsDismissed)")
        LabeledContent("Average backend latency", value: averageLatencyTitle(snapshot.averageBackendLatencyMs))
        if let latencyReport = snapshot.lastLatencyReport {
            Text("Latest latency report")
                .font(.caption.weight(.medium))
            Text(latencyReport.redactedReport)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            Button("Copy Redacted Latency Report") {
                copyLatencyReport(latencyReport)
            }
        } else {
            Text("No latency report yet.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        Text("Counters and latency reports are stored locally as numbers only. Accepted text, prompts, suggestions, clipboard, OCR, app names, bundle IDs, and domains are not stored in metrics.")
            .font(.caption)
            .foregroundStyle(.secondary)
        Button("Reset Productivity Metrics", role: .destructive) {
            reset()
        }
        .disabled(!hasMetrics(snapshot))
    }

    private func averageLatencyTitle(_ latencyMs: Int?) -> String {
        latencyMs.map { "\($0) ms" } ?? "No samples"
    }

    private func hasMetrics(_ snapshot: ProductivityMetricsSnapshot) -> Bool {
        snapshot.wordsAcceptedToday > 0
            || snapshot.wordsAcceptedTotal > 0
            || snapshot.suggestionsAccepted > 0
            || snapshot.suggestionsDismissed > 0
            || snapshot.latencySampleCount > 0
            || snapshot.lastLatencyReport != nil
    }

    private func copyLatencyReport(_ report: CompletionLatencyReport) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report.redactedReport, forType: .string)
    }
}

struct ShortcutSettingsView: View {
    @EnvironmentObject private var controller: AppController
    @State private var settings = KeyboardShortcutSettings.defaults
    @State private var recordingCommand: KeyboardShortcutCommand?

    var body: some View {
        Form {
            Section("Acceptance") {
                shortcutRow(.acceptNextWord)
                shortcutRow(.acceptFullSuggestion)
            }

            Section("Commands") {
                shortcutRow(.manualTrigger)
                shortcutRow(.dismissSuggestion)
                shortcutRow(.toggleAutocomplete)
            }

            Section {
                Button("Restore Defaults") {
                    settings = .defaults
                    recordingCommand = nil
                    controller.saveKeyboardShortcutSettings(settings)
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("Shortcuts")
        .onAppear {
            settings = controller.shortcutSettingsStore.load()
        }
    }

    private func shortcutRow(_ command: KeyboardShortcutCommand) -> some View {
        HStack {
            Text(command.title)
            Spacer()
            ShortcutRecorderButton(
                binding: settings[command],
                isRecording: recordingCommand == command,
                startRecording: {
                    recordingCommand = command
                },
                record: { binding in
                    settings[command] = binding
                    recordingCommand = nil
                    controller.saveKeyboardShortcutSettings(settings)
                },
                cancel: {
                    recordingCommand = nil
                }
            )
        }
    }
}

private struct ShortcutRecorderButton: View {
    let binding: KeyboardShortcutBinding
    let isRecording: Bool
    let startRecording: () -> Void
    let record: (KeyboardShortcutBinding) -> Void
    let cancel: () -> Void

    var body: some View {
        Button(isRecording ? "Recording..." : binding.displayName) {
            startRecording()
        }
        .buttonStyle(.bordered)
        .background(
            ShortcutCaptureView(
                isActive: isRecording,
                record: record,
                cancel: cancel
            )
            .frame(width: 0, height: 0)
        )
    }
}

private struct ShortcutCaptureView: NSViewRepresentable {
    let isActive: Bool
    let record: (KeyboardShortcutBinding) -> Void
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
    var record: ((KeyboardShortcutBinding) -> Void)?
    var cancel: (() -> Void)?

    override var acceptsFirstResponder: Bool {
        true
    }

    override func keyDown(with event: NSEvent) {
        guard isActive else {
            return
        }

        let modifiers = KeyboardShortcutModifiers(nsEventFlags: event.modifierFlags)
        if event.keyCode == CapturedInputEventAdapter.escapeKeyCode,
           modifiers.isEmpty {
            cancel?()
            return
        }

        record?(KeyboardShortcutBinding(event: event, trigger: .keyDown))
    }

    override func flagsChanged(with event: NSEvent) {
        guard isActive else {
            return
        }

        let modifiers = KeyboardShortcutModifiers(nsEventFlags: event.modifierFlags)
        guard !modifiers.isEmpty else {
            return
        }

        record?(KeyboardShortcutBinding(event: event, trigger: .flagsChanged))
    }
}

@MainActor
struct ModelSettingsView: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var engine: SuggestionEngine
    @EnvironmentObject private var localRuntimeStatusStore: LocalLlamaRuntimeStatusStore
    @StateObject private var modelDownloadManager = ModelDownloadManager()
    @StateObject private var runtimeBootstrapModel = RuntimeBootstrapModel()
    @State private var draft = CompletionBackendSettings()
    @State private var selectedRemotePreset = RemoteEndpointPreset.custom
    @State private var connectionTestState = RemoteConnectionTestState.idle
    @State private var localModelActionState: LocalModelActionState?
    @State private var playgroundPrefix = "Please write "
    @State private var playgroundSuffix = ""
    @State private var playgroundResult: CompletionPlaygroundResult?
    @State private var playgroundError: String?
    @State private var isPlaygroundRunning = false
    @State private var didRunPlaygroundUITest = false
    @State private var debugOptions = AutoCompDebugOptions()
    @State private var backendSaveMessage: String?
    @State private var remoteConsentRevision = 0

    var body: some View {
        Form {
            Section("Backend selection") {
                Picker("Selected backend", selection: $draft.engineKind) {
                    ForEach(CompletionEngineKind.allCases, id: \.self) { kind in
                        Text(kind.displayName).tag(kind)
                    }
                }
                LabeledContent("Request destination", value: draft.requestDestinationTitle)
                LabeledContent("Data leaves this Mac", value: draft.dataLeavesDeviceTitle)
                LabeledContent("Remote fallback", value: draft.remoteFallbackTitle)
                LabeledContent("Stop sequences", value: draft.stopSequenceSummaryTitle)
                LabeledContent("Stop behavior", value: draft.stopSequenceBehaviorTitle)
                if let warning = draft.remoteFallbackWarning {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }

            Section("Remote completion consent") {
                let requirements = draft.remoteConsentRequirements
                if requirements.isEmpty {
                    Text(draft.remoteConsentLocalOnlyDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    LabeledContent("Remote endpoint", value: draft.remoteBaseURL)
                    LabeledContent("Endpoint type", value: draft.remoteConsentEndpointKindTitle)
                    Text("Remote consent is saved per endpoint. Changing the remote endpoint requires consent again.")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    ForEach(requirements) { requirement in
                        let hasConsent = controller.hasRemoteCompletionConsent(
                            for: requirement.scope,
                            settings: draft
                        )
                        VStack(alignment: .leading, spacing: 6) {
                            HStack {
                                Text(requirement.title)
                                    .font(.caption.weight(.medium))
                                Spacer()
                                Text(hasConsent ? "Allowed" : "Needs consent")
                                    .font(.caption.weight(.medium))
                                    .foregroundStyle(hasConsent ? .green : .orange)
                            }
                            Text(requirement.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if hasConsent {
                                Text("Consent is saved for this endpoint.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            } else {
                                Button(requirement.buttonTitle) {
                                    controller.grantRemoteCompletionConsent(
                                        for: requirement.scope,
                                        settings: draft
                                    )
                                    remoteConsentRevision += 1
                                }
                            }
                        }
                    }
                }

                Button("Reset Remote Completion Consent", role: .destructive) {
                    controller.resetRemoteCompletionConsent()
                    remoteConsentRevision += 1
                }
            }

            Section("Remote backend settings") {
                Text("These settings are used when Remote OpenAI-compatible is selected, and by remote fallback for Apple Intelligence or Local Llama.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Picker("Endpoint preset", selection: $selectedRemotePreset) {
                    ForEach(RemoteEndpointPreset.allCases) { preset in
                        Text(preset.title).tag(preset)
                    }
                }
                .onChange(of: selectedRemotePreset) { _, preset in
                    guard let baseURL = preset.baseURL else {
                        return
                    }
                    draft.remoteBaseURL = baseURL
                }
                TextField("Base URL", text: $draft.remoteBaseURL)
                    .onChange(of: draft.remoteBaseURL) { _, baseURL in
                        selectedRemotePreset = RemoteEndpointPreset.matching(baseURL)
                    }
                SecureField("API key", text: $draft.remoteAPIKey)
                TextField("Model", text: $draft.remoteModel)

                HStack {
                    Button("Test Connection") {
                        testRemoteConnection()
                    }
                    .accessibilityLabel("Test Connection")
                    .disabled(connectionTestState.isTesting)

                    if connectionTestState.isTesting {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                connectionStatusView
            }

            Section("Model compatibility evidence") {
                let recommendation = ModelCompatibilityMatrix.bundled.recommendation(for: draft)
                LabeledContent("Matrix row", value: recommendation.rowTitle)
                LabeledContent("FIM behavior", value: recommendation.fimTitle)
                LabeledContent("Multiple completions", value: recommendation.multipleCompletionsTitle)
                LabeledContent("Latency", value: recommendation.latencyTitle)
                LabeledContent("Evidence", value: recommendation.evidenceTitle)
                Text(recommendation.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Apply changes") {
                Button("Save and Use Selected Backend") {
                    saveBackend()
                }
                if let backendSaveMessage {
                    Text(backendSaveMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Model Playground") {
                Text("Prefix")
                    .font(.caption.weight(.medium))
                PlaygroundTextView(text: $playgroundPrefix, onTab: acceptPlaygroundSuggestion)
                    .frame(minHeight: 90)

                TextField("Suffix after cursor", text: $playgroundSuffix)

                HStack {
                    Button("Run Playground") {
                        runPlaygroundCompletion()
                    }
                    .disabled(isPlaygroundRunning)

                    Button("Accept Result") {
                        _ = acceptPlaygroundSuggestion()
                    }
                    .disabled(playgroundResult?.normalizedOutput.isEmpty != false)

                    if isPlaygroundRunning {
                        ProgressView()
                            .controlSize(.small)
                    }
                }

                let preview = controller.playgroundPreview(
                    prefix: playgroundPrefix,
                    suffix: playgroundSuffix,
                    settings: draft
                )
                LabeledContent("Mode", value: preview.modeTitle)
                LabeledContent("Request destination", value: preview.requestDestinationTitle)
                LabeledContent("Data leaves this Mac", value: preview.dataLeavesDeviceTitle)
                LabeledContent("Remote fallback", value: preview.remoteFallbackTitle)
                if let promptPreview = preview.promptPreview(options: debugOptions) {
                    Text("Prompt preview")
                        .font(.caption.weight(.medium))
                    Text(promptPreview)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    Text("Prompt preview hidden until local debug opt-in is enabled in Privacy.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let playgroundResult {
                    LabeledContent("Latency", value: "\(playgroundResult.latencyMs) ms")
                    Text("Raw output")
                        .font(.caption.weight(.medium))
                    Text(playgroundResult.rawOutput)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                    Text("Normalized output")
                        .font(.caption.weight(.medium))
                    Text(playgroundResult.normalizedOutput)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.green)
                        .textSelection(.enabled)
                }

                if let playgroundError {
                    Text(playgroundError)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Section("Local model") {
                if runtimeBootstrapModel.availableModels.isEmpty {
                    Text("No local GGUF models found in \(modelDownloadManager.modelsDirectoryPath).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Picker("Installed model", selection: localModelSelectionBinding) {
                        Text("Choose a model").tag("")
                        ForEach(runtimeBootstrapModel.availableModels) { model in
                            Text("\(model.displayName) (\(model.sizeLabel))").tag(model.url.path)
                        }
                    }
                }

                TextField("Model path", text: $draft.localModelPath)
                TextField("Max RAM bytes", text: localMaxRAMBinding)
                Toggle("Fallback to remote if local fails", isOn: $draft.fallbackToRemoteOnLocalFailure)
                if draft.fallbackToRemoteOnLocalFailure {
                    Text("Remote fallback is enabled: if local completion fails, autocomplete text may be sent to \(draft.remoteBaseURL).")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                HStack {
                    Button("Choose GGUF") {
                        chooseLocalGGUF()
                    }
                    Button("Open Models Folder") {
                        openModelsDirectory()
                    }
                    Button("Refresh") {
                        refreshLocalModels()
                    }
                    Button("Unload Local Model") {
                        controller.unloadLocalLlamaRuntime()
                    }
                    .disabled(controller.completionBackendSettings.engineKind != .localLlama)
                }

                if let localModelActionState {
                    Text(localModelActionState.message)
                        .font(.caption)
                        .foregroundStyle(localModelActionState.color)
                }
            }

            Section("Recommended local models") {
                ForEach(modelDownloadManager.models) { model in
                    recommendedModelRow(model)
                }
            }

            Section("Local diagnostics") {
                let diagnostic = draft.localDiagnostic(loadStatus: localRuntimeStatusStore.status)
                LabeledContent("Bootstrap", value: runtimeBootstrapModel.state.summary)
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

            Section("Apple Intelligence diagnostics") {
                let diagnostic = draft.appleIntelligenceDiagnostic()
                LabeledContent("Availability", value: diagnostic.availabilityTitle)
                LabeledContent("Requirement", value: diagnostic.requirementTitle)
                Toggle("Fallback to remote if Apple fails", isOn: $draft.fallbackToRemoteOnAppleIntelligenceFailure)
                LabeledContent("Fallback", value: diagnostic.fallbackTitle)
                if draft.fallbackToRemoteOnAppleIntelligenceFailure {
                    Text("Apple Intelligence fallback uses the remote backend settings above.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("Apple Intelligence is optional. It requires FoundationModels in the build SDK and a supported macOS release; remote fallback is used only when enabled.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if debugOptions.localDebugOptIn || draft.multiSuggestionEnabled {
                Section("Internal suggestions") {
                    Toggle("Enable multi-suggestion popup", isOn: $draft.multiSuggestionEnabled)
                    Text("Internal/debug only. Keep disabled for beta QA unless this run explicitly validates multi-suggestion behavior.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section("Active backend") {
                let activeSettings = controller.completionBackendSettings
                LabeledContent("Active backend", value: controller.completionBackendSummary)
                LabeledContent("Current engine", value: activeSettings.engineKind.displayName)
                LabeledContent("Request destination", value: activeSettings.requestDestinationTitle)
                LabeledContent("Data leaves this Mac", value: activeSettings.dataLeavesDeviceTitle)
                LabeledContent("Remote fallback", value: activeSettings.remoteFallbackTitle)
                LabeledContent("Stop sequences", value: activeSettings.stopSequenceSummaryTitle)
                LabeledContent("Stop behavior", value: activeSettings.stopSequenceBehaviorTitle)
                LabeledContent("Last backend used", value: engine.diagnostics.backend.lastUsedTitle)
                LabeledContent("Connection", value: engine.backendStatusSummary.menuTitle)
                LabeledContent(
                    "Last local error",
                    value: engine.diagnostics.backend.errorTitle(
                        for: .localLlama,
                        storedLocalError: activeSettings.localLastError
                    )
                )
                LabeledContent(
                    "Last Apple error",
                    value: engine.diagnostics.backend.errorTitle(for: .appleIntelligence)
                )
                LabeledContent(
                    "Last remote error",
                    value: engine.diagnostics.backend.errorTitle(for: .remote)
                )
                Button("Reload Saved Backend") {
                    reloadSavedBackend()
                }
            }

            Section("Privacy") {
                Text("Autocomplete text is sent to the request destination above, and to the remote backend only when remote fallback is enabled after a local or Apple failure.")
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle("Model")
        .onAppear {
            draft = controller.completionBackendSettings
            debugOptions = controller.debugOptions()
            selectedRemotePreset = RemoteEndpointPreset.matching(draft.remoteBaseURL)
            connectionTestState = .idle
            backendSaveMessage = nil
            modelDownloadManager.onModelDirectoryChanged = {
                runtimeBootstrapModel.refreshAvailableModels()
            }
            refreshLocalModels()
            runPlaygroundUITestIfNeeded()
        }
    }

    private func saveBackend() {
        controller.saveCompletionBackendSettings(draft)
        draft = controller.completionBackendSettings
        selectedRemotePreset = RemoteEndpointPreset.matching(draft.remoteBaseURL)
        backendSaveMessage = savedBackendMessage(for: draft)
    }

    private func reloadSavedBackend() {
        controller.refreshCompletionBackendSettings()
        draft = controller.completionBackendSettings
        selectedRemotePreset = RemoteEndpointPreset.matching(draft.remoteBaseURL)
        connectionTestState = .idle
        backendSaveMessage = nil
    }

    private func savedBackendMessage(for settings: CompletionBackendSettings) -> String {
        switch settings.engineKind {
        case .remote:
            return "Saved Remote OpenAI-compatible: \(settings.remoteModel) at \(settings.remoteBaseURL)."
        case .localLlama:
            return "Saved Local Llama as the selected backend."
        case .appleIntelligence:
            return "Saved Apple Intelligence as the selected backend."
        }
    }

    @ViewBuilder
    private var connectionStatusView: some View {
        switch connectionTestState {
        case .idle, .testing:
            EmptyView()
        case .connected(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.green)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
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

    private var localModelSelectionBinding: Binding<String> {
        Binding {
            runtimeBootstrapModel.selectedModel(for: draft.localModelPath)?.url.path ?? ""
        } set: { path in
            guard !path.isEmpty,
                  let url = runtimeBootstrapModel.availableModels.first(where: { $0.url.path == path })?.url else {
                return
            }
            useLocalModel(url)
        }
    }

    private func testRemoteConnection() {
        connectionTestState = .testing
        Task { @MainActor in
            let result = await controller.testRemoteConnection(settings: draft)
            if draft.remoteModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               let suggestedModel = result.suggestedModel {
                draft.remoteModel = suggestedModel
            }
            connectionTestState = RemoteConnectionTestState(result)
        }
    }

    private func runPlaygroundCompletion() {
        isPlaygroundRunning = true
        playgroundError = nil
        Task { @MainActor in
            do {
                playgroundResult = try await controller.completePlayground(
                    prefix: playgroundPrefix,
                    suffix: playgroundSuffix,
                    settings: draft
                )
            } catch {
                playgroundResult = nil
                playgroundError = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isPlaygroundRunning = false
        }
    }

    @discardableResult
    private func acceptPlaygroundSuggestion() -> Bool {
        guard let normalizedOutput = playgroundResult?.normalizedOutput,
              !normalizedOutput.isEmpty else {
            return false
        }

        playgroundPrefix += normalizedOutput
        playgroundResult = nil
        playgroundError = nil
        return true
    }

    private func runPlaygroundUITestIfNeeded() {
        guard controller.isPlaygroundUITestMode,
              !didRunPlaygroundUITest else {
            return
        }

        didRunPlaygroundUITest = true
        playgroundPrefix = "Playground prefix "
        playgroundSuffix = " after suffix."
        runPlaygroundCompletion()
    }

    @ViewBuilder
    private func recommendedModelRow(_ model: DownloadableLocalModel) -> some View {
        let state = modelDownloadManager.state(for: model)

        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.displayName)
                    .font(.headline)
                Spacer()
                Text(model.approximateSizeLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Text(model.filename)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            HStack {
                Text(state.statusText)
                    .font(.caption)
                    .foregroundStyle(statusColor(for: state))
                Spacer()
                recommendedModelAction(model, state: state)
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func recommendedModelAction(
        _ model: DownloadableLocalModel,
        state: ModelDownloadState
    ) -> some View {
        switch state {
        case .loading(let progress):
            if let progress {
                ProgressView(value: progress)
                    .frame(width: 72)
            } else {
                ProgressView()
                    .controlSize(.small)
            }
            Button("Cancel") {
                modelDownloadManager.cancel(filename: model.filename)
            }
        case .ready:
            Button("Use") {
                if let url = modelDownloadManager.installedModelURL(for: model) {
                    useLocalModel(url)
                }
            }
        case .failed:
            Button("Retry Download") {
                modelDownloadManager.download(model)
            }
        case .idle:
            Button("Download") {
                modelDownloadManager.download(model)
            }
        }
    }

    private func statusColor(for state: ModelDownloadState) -> Color {
        switch state {
        case .ready:
            return .green
        case .failed:
            return .red
        default:
            return .secondary
        }
    }

    private func chooseLocalGGUF() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let ggufType = UTType(filenameExtension: "gguf") {
            panel.allowedContentTypes = [ggufType]
        }

        guard panel.runModal() == .OK,
              let url = panel.url else {
            return
        }

        useLocalModel(url)
    }

    private func useLocalModel(_ url: URL) {
        do {
            try ModelFileValidator.validateGGUFFile(at: url)
            var updatedDraft = draft
            updatedDraft.engineKind = .localLlama
            updatedDraft.localModelPath = url.path
            updatedDraft.localLastError = nil
            draft = updatedDraft
            controller.saveCompletionBackendSettings(updatedDraft)
            refreshLocalModels()
            localModelActionState = .ready("Using \(url.lastPathComponent)")
        } catch {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            draft.localLastError = message
            localModelActionState = .failed(message)
        }
    }

    private func openModelsDirectory() {
        do {
            try FileManager.default.createDirectory(
                at: modelDownloadManager.modelsDirectory,
                withIntermediateDirectories: true
            )
            NSWorkspace.shared.open(modelDownloadManager.modelsDirectory)
        } catch {
            localModelActionState = .failed(error.localizedDescription)
        }
    }

    private func refreshLocalModels() {
        runtimeBootstrapModel.refreshAvailableModels()
        modelDownloadManager.refreshModelStates()
    }
}

private enum RemoteEndpointPreset: String, CaseIterable, Identifiable {
    case lmStudio
    case ollama
    case llamaCpp
    case vLLMLocalAI
    case custom

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lmStudio:
            return "LM Studio"
        case .ollama:
            return "Ollama"
        case .llamaCpp:
            return "llama.cpp server"
        case .vLLMLocalAI:
            return "vLLM / LocalAI"
        case .custom:
            return "Custom"
        }
    }

    var baseURL: String? {
        switch self {
        case .lmStudio:
            return "http://127.0.0.1:1234"
        case .ollama:
            return "http://127.0.0.1:11434"
        case .llamaCpp:
            return "http://127.0.0.1:8080"
        case .vLLMLocalAI:
            return "http://127.0.0.1:8000"
        case .custom:
            return nil
        }
    }

    static func matching(_ baseURL: String) -> RemoteEndpointPreset {
        allCases.first { preset in
            guard let presetURL = preset.baseURL else {
                return false
            }
            return presetURL == baseURL
        } ?? .custom
    }
}

private enum RemoteConnectionTestState: Equatable {
    case idle
    case testing
    case connected(String)
    case failed(String)

    init(_ result: RemoteBackendProbeResult) {
        switch result.status {
        case .connected:
            self = .connected(result.message)
        case .failed:
            self = .failed(result.message)
        }
    }

    var isTesting: Bool {
        self == .testing
    }
}

private enum LocalModelActionState: Equatable {
    case ready(String)
    case failed(String)

    var message: String {
        switch self {
        case .ready(let message),
             .failed(let message):
            return message
        }
    }

    var color: Color {
        switch self {
        case .ready:
            return .green
        case .failed:
            return .red
        }
    }
}

private struct PlaygroundTextView: NSViewRepresentable {
    @Binding var text: String
    let onTab: () -> Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.borderType = .bezelBorder

        let textView = PlaygroundNSTextView(frame: .zero)
        textView.delegate = context.coordinator
        textView.onTab = onTab
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.allowsUndo = true
        textView.font = NSFont.systemFont(ofSize: NSFont.systemFontSize)
        textView.textContainerInset = NSSize(width: 6, height: 6)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.containerSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        textView.string = text

        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? PlaygroundNSTextView else {
            return
        }
        textView.onTab = onTab
        if textView.string != text {
            textView.string = text
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        @Binding private var text: String

        init(text: Binding<String>) {
            _text = text
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else {
                return
            }
            text = textView.string
        }
    }
}

private final class PlaygroundNSTextView: NSTextView {
    var onTab: (() -> Bool)?

    override func keyDown(with event: NSEvent) {
        if event.keyCode == CapturedInputEventAdapter.tabKeyCode,
           onTab?() == true {
            return
        }
        super.keyDown(with: event)
    }
}
