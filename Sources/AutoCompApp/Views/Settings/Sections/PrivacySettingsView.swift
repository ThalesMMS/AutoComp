import AutoCompCore
import SwiftUI

struct PrivacySettingsView: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var engine: SuggestionEngine
    @State private var settings = PrivacySettings()
    @State private var debugOptions = AutoCompDebugOptions()
    @State private var recordCount = 0
    @State private var personalizationSummary = PersonalizationStoreSummary.empty
    @State private var draftWritingRule = ""
    @State private var draftLanguageHint = ""
    @State private var draftPrivacyDomain = ""
    @State private var draftDomainCollectionAllowed = false
    @State private var privacyDataMessage: String?

    var body: some View {
        SettingsPaneForm(title: "Privacy") {
            Section("Collection") {
                SectionFooterNote(text: "Choose which optional local context can help shape a suggestion.")
                Toggle("Enable optional local input collection", isOn: privacyBinding(\.collectionEnabled))
                Toggle("Use clipboard as local context", isOn: privacyBinding(\.clipboardContextEnabled))
                Toggle("Use visible screen text as local context", isOn: privacyBinding(\.screenContextEnabled))
                Slider(value: personalizationStrengthBinding, in: 0...1) {
                    Text("Personalization strength")
                }
            }

            Section("Local personalization") {
                Toggle("Keep local writing samples", isOn: privacyBinding(\.localPersonalizationEnabled))
                SettingsActionRow(
                    title: "Status",
                    subtitle: localPersonalizationStatusSubtitle,
                    state: settings.localPersonalizationEnabled && settings.collectionEnabled ? .ok : .disabled,
                    statusTitle: settings.localPersonalizationEnabled && settings.collectionEnabled ? "On" : "Off"
                )
                LabeledContent("Stored samples", value: "\(personalizationSummary.sampleCount)")
                LabeledContent("Latest sample", value: latestPersonalizationSampleTitle)
                DisclosureGroup("Storage details") {
                    SectionFooterNote(text: "Samples are short encrypted excerpts stored locally. This summary never shows captured text.")
                }
            }

            Section("Source policy") {
                SettingsActionRow(
                    title: "Editing text",
                    subtitle: "Used to write the suggestion you requested.",
                    state: .ok,
                    statusTitle: "Core"
                )
                SettingsActionRow(
                    title: "Optional context",
                    subtitle: "Clipboard and visible screen text stay off until enabled.",
                    state: settings.collectionEnabled ? .pending : .disabled,
                    statusTitle: settings.collectionEnabled ? "Opt-in" : "Off"
                )
                DisclosureGroup("Technical source policy") {
                    SettingsActionRow(
                        title: "Local diagnostics",
                        subtitle: "Sensitive debug previews require Developer opt-in.",
                        state: debugOptions.allowsSensitivePromptPreview ? .warning : .disabled,
                        statusTitle: debugOptions.allowsSensitivePromptPreview ? "Enabled" : "Off"
                    )
                    privacyPolicyTable(rows: privacyPolicyRows)
                }
            }

            Section("Domain collection rules") {
                SettingsActionRow(
                    title: "Domain rules",
                    subtitle: "Saved domains override app-level collection settings.",
                    state: domainPrivacyRows.isEmpty ? .disabled : .ok,
                    statusTitle: domainPrivacyRows.isEmpty ? "None" : "\(domainPrivacyRows.count)"
                )
                DisclosureGroup("Matching details") {
                    SectionFooterNote(text: "Browser domains use the active tab host. The most specific saved rule applies before app-level collection rules.")
                }

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
                SectionFooterNote(text: "Rules shape tone and style. Language hints are soft: surrounding text still wins.")

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

                    HStack {
                        Button("Clear rules") {
                            clearWritingRules()
                        }
                        .disabled(settings.writingPreferences.rules.isEmpty)

                        Button("Clear language hints") {
                            clearLanguageHints()
                        }
                        .disabled(settings.writingPreferences.languageHints.isEmpty)
                    }

                    if !settings.writingPreferences.languageHints.isEmpty {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 150), alignment: .leading)],
                            alignment: .leading,
                            spacing: 8
                        ) {
                            ForEach(settings.writingPreferences.languageHints, id: \.self) { hint in
                                languageHintChip(hint)
                            }
                        }
                    }

                    HStack {
                        TextField("Add language hint", text: $draftLanguageHint)
                            .onSubmit(commitDraftLanguageHints)
                            .onChange(of: draftLanguageHint) { _, value in
                                guard value.contains(",") else {
                                    return
                                }
                                commitDraftLanguageHints()
                            }
                        Button("Add") {
                            commitDraftLanguageHints()
                        }
                        .disabled(!draftHasAddableLanguageHint)
                    }

                    LabeledContent(
                        "Language hints",
                        value: "\(settings.writingPreferences.languageHints.count)/\(WritingPreferences.maxLanguageHints)"
                    )

                    if let promptPreview = settings.writingPreferences.promptPreview {
                        Text("Preference prompt block")
                            .font(.caption.weight(.medium))
                        Text(promptPreview)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
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

                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 120), alignment: .leading)],
                        alignment: .leading,
                        spacing: 8
                    ) {
                        ForEach(WritingPreferences.suggestedLanguageHints, id: \.self) { hint in
                            Button(hint) {
                                addLanguageHint(hint)
                            }
                            .disabled(!canAddLanguageHint(hint))
                        }
                    }
                }
            }

            Section("Completion backend") {
                let backendSettings = controller.completionBackendSettings
                let backendSurface = BackendSurface(settings: backendSettings)
                SettingsActionRow(
                    title: "Request destination",
                    subtitle: backendSurface.privacySummary,
                    state: backendPrivacyState(backendSurface),
                    statusTitle: backendSurface.privacyStatusTitle
                )
                DisclosureGroup("Backend privacy details") {
                    LabeledContent("Active engine", value: backendSettings.engineKind.displayName)
                    LabeledContent("Request destination", value: backendSurface.requestDestinationTitle)
                    LabeledContent("Data leaves this Mac", value: backendSurface.dataLeavesDeviceTitle)
                    LabeledContent("Remote fallback", value: backendSurface.remoteFallbackTitle)
                    LabeledContent("Last backend used", value: engine.diagnostics.backend.lastUsedTitle)
                    SectionFooterNote(text: "Privacy controls limit optional local context. The selected completion backend still receives the autocomplete request shown here.")
                }
            }

            Section("Local data") {
                LabeledContent("Encrypted records", value: "\(recordCount)")
                DangerZoneView(
                    title: "Delete local privacy data",
                    message: "Removes local personalization, counters, and debug artifacts stored on this Mac."
                ) {
                    Button("Delete Local Personalization Data", role: .destructive) {
                        controller.deletePersonalizationData()
                        settings = controller.privacySettingsStore.load()
                        refreshPersonalizationSummary()
                    }
                    Button("Delete All Local Privacy Data", role: .destructive) {
                        deleteAllLocalPrivacyData()
                    }
                }
                if let privacyDataMessage {
                    StatusBadge(privacyDataMessage, state: privacyDataMessage.contains("Unable") ? .error : .ok)
                }
            }

        }
        .onAppear {
            settings = controller.privacySettingsStore.load()
            refreshPersonalizationSummary()
            debugOptions = controller.debugOptions()
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
                source: "Local writing samples",
                defaultState: "Off",
                purpose: "Opt-in local personalization",
                remoteBackend: remoteBackendExposure(sourceEnabled: settings.localPersonalizationEnabled),
                turnOff: "Privacy > Keep local writing samples",
                retention: "Encrypted local excerpts until deleted"
            ),
            PrivacyPolicyRow(
                source: "Debug logs",
                defaultState: "Sensitive content off",
                purpose: "Diagnostics",
                remoteBackend: "No",
                turnOff: "Developer > Debug",
                retention: "Sensitive artifacts stay local until deleted"
            ),
            PrivacyPolicyRow(
                source: "Productivity metrics",
                defaultState: "On",
                purpose: "Local value feedback",
                remoteBackend: "No",
                turnOff: "Statistics > Keep local productivity counters",
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
        // PrivacySettings.normalizedDomain legacy contract: domain input is canonicalized before saving.
        DomainNormalization.canonicalDomainStringAllowingEmpty(from: draftPrivacyDomain)
    }

    private var localPersonalizationStatusSubtitle: String {
        if !settings.localPersonalizationEnabled {
            return "Writing samples are not stored."
        }
        if !settings.collectionEnabled {
            return "Enable optional local input collection before samples can be recorded."
        }
        return "Records short encrypted excerpts that match app and domain rules."
    }

    private var latestPersonalizationSampleTitle: String {
        guard let newestSampleDate = personalizationSummary.newestSampleDate else {
            return "None"
        }
        return newestSampleDate.formatted(date: .abbreviated, time: .shortened)
    }

    private func remoteBackendExposure(sourceEnabled: Bool) -> String {
        BackendSurface(settings: controller.completionBackendSettings)
            .remoteBackendExposureTitle(sourceEnabled: sourceEnabled)
    }

    private func backendPrivacyState(_ surface: BackendSurface) -> SettingsVisualState {
        surface.exposesAutocompleteTextRemotely ? .warning : .ok
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

    private var draftHasAddableLanguageHint: Bool {
        draftLanguageHint
            .split(separator: ",", omittingEmptySubsequences: false)
            .map(String.init)
            .contains(where: canAddLanguageHint)
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
        refreshPersonalizationSummary()
    }

    private func deleteAllLocalPrivacyData() {
        do {
            try controller.deleteAllLocalPrivacyData()
            settings = controller.privacySettingsStore.load()
            refreshPersonalizationSummary()
            debugOptions = controller.debugOptions()
            privacyDataMessage = "Personalization, writing preferences, productivity metrics, and debug artifacts deleted."
        } catch {
            refreshPersonalizationSummary()
            debugOptions = controller.debugOptions()
            privacyDataMessage = "Unable to delete all local privacy data: \(error.localizedDescription)"
        }
    }

    private func refreshPersonalizationSummary() {
        personalizationSummary = controller.personalizationStore.summary()
        recordCount = personalizationSummary.sampleCount
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

    private func commitDraftLanguageHints() {
        let rawHints = draftLanguageHint
            .split(separator: ",", omittingEmptySubsequences: false)
            .map(String.init)

        var updatedPreferences = settings.writingPreferences
        for hint in rawHints {
            updatedPreferences = updatedPreferences.addingLanguageHint(hint)
        }

        var updatedSettings = settings
        updatedSettings.writingPreferences = updatedPreferences
        save(updatedSettings)
        draftLanguageHint = ""
    }

    private func addLanguageHint(_ hint: String) {
        var updatedSettings = settings
        updatedSettings.writingPreferences = updatedSettings.writingPreferences.addingLanguageHint(hint)
        save(updatedSettings)
    }

    private func removeLanguageHint(_ hint: String) {
        var updatedSettings = settings
        updatedSettings.writingPreferences = updatedSettings.writingPreferences.removingLanguageHint(hint)
        save(updatedSettings)
    }

    private func clearWritingRules() {
        var updatedSettings = settings
        updatedSettings.writingPreferences = WritingPreferences(
            enabled: updatedSettings.writingPreferences.enabled,
            languageHints: updatedSettings.writingPreferences.languageHints
        )
        save(updatedSettings)
    }

    private func clearLanguageHints() {
        var updatedSettings = settings
        updatedSettings.writingPreferences = WritingPreferences(
            enabled: updatedSettings.writingPreferences.enabled,
            rules: updatedSettings.writingPreferences.rules
        )
        save(updatedSettings)
    }

    private func canAddLanguageHint(_ hint: String) -> Bool {
        let normalized = WritingPreferences.normalizedLanguageHint(hint)
        guard !normalized.isEmpty,
              settings.writingPreferences.languageHints.count < WritingPreferences.maxLanguageHints else {
            return false
        }

        return !settings.writingPreferences.languageHints
            .map { WritingPreferences.normalizedLanguageHint($0).lowercased() }
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

    private func languageHintChip(_ hint: String) -> some View {
        HStack(spacing: 6) {
            Text(hint)
                .lineLimit(1)
                .truncationMode(.tail)
            Button {
                removeLanguageHint(hint)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove language hint")
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
