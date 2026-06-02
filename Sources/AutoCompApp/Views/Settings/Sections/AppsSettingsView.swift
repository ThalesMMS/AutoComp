import AutoCompCore
import AppKit
import SwiftUI

struct AppCompatibilitySettingsView: View {
    @EnvironmentObject private var controller: AppController
    @State private var overrides: [String: CompatibilityOverrideMode] = [:]
    @State private var installedApps: [InstalledApplication] = []
    @State private var searchText = ""
    @State private var domainText = ""
    @State private var newDomainMode: CompatibilityOverrideMode = .manualOnly
    @State private var isScanningApps = false
    @State private var isConfirmingOverrideReset = false

    private var filteredApps: [InstalledApplication] {
        InstalledApplicationFilter.filter(installedApps, matching: searchText)
    }

    private var appOverrideCount: Int {
        overrides.keys.filter { !$0.hasPrefix("domain:") }.count
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

    private var domainRuleConflicts: [DomainRuleConflictRow] {
        let domains = domainRows.map(\.domain)
        var conflicts: [DomainRuleConflictRow] = []

        for i in 0..<domains.count {
            for j in (i + 1)..<domains.count {
                let a = domains[i]
                let b = domains[j]
                if domainsConflict(a: a, b: b) {
                    conflicts.append(DomainRuleConflictRow(domainA: a, domainB: b))
                }
            }
        }

        return conflicts.sorted { lhs, rhs in
            if lhs.domainA != rhs.domainA { return lhs.domainA < rhs.domainA }
            return lhs.domainB < rhs.domainB
        }
    }

    var body: some View {
        SettingsPaneForm(title: "Apps") {
            FocusedAppSection(
                focusTrackingModel: controller.focusTrackingModel,
                catalog: controller.compatibilityCatalog,
                overrides: $overrides,
                installedApps: installedApps,
                setAppMode: setMode(_:for:),
                setDomainMode: setDomainMode(_:for:),
                revealApp: revealApp(bundleID:)
            )

            installedAppsSection
            domainRulesSection
            advancedSection
        }
        .onAppear {
            overrides = controller.compatibilitySettings.loadModeOverrides()
            if installedApps.isEmpty {
                reloadInstalledApps()
            }
        }
        .confirmationDialog(
            "Reset Compatibility Overrides?",
            isPresented: $isConfirmingOverrideReset,
            titleVisibility: .visible
        ) {
            Button("Reset All Compatibility Overrides", role: .destructive) {
                restoreDefaults()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes app and domain overrides. Catalog defaults will apply again.")
        }
    }

    @ViewBuilder
    private var installedAppsSection: some View {
        Section("Installed apps") {
            SectionFooterNote(text: "Search by app name or bundle ID. Scans installed application folders, not only running apps.")
            HStack(spacing: 8) {
                TextField("Search apps", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                Button {
                    reloadInstalledApps()
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .help("Refresh installed apps")
                .disabled(isScanningApps)
            }

            if isScanningApps {
                ProgressView("Scanning installed apps")
            } else if filteredApps.isEmpty {
                SectionFooterNote(text: searchText.isEmpty ? "No installed apps found." : "No apps match the search.")
            } else {
                ForEach(filteredApps) { app in
                    appRow(app)
                }
            }
        }
    }

    @ViewBuilder
    private var domainRulesSection: some View {
        Section("Domain rules") {
            SectionFooterNote(text: "Domain rules are separate from bundle ID overrides and win for matching browser hosts.")
            domainRuleCreator

            if domainRows.isEmpty {
                SectionFooterNote(text: "No domain rules.")
            } else {
                ForEach(domainRows) { row in
                    domainRuleRow(row)
                }

                let conflicts = domainRuleConflicts
                if !conflicts.isEmpty {
                    Divider()
                    VStack(alignment: .leading, spacing: 6) {
                        StatusBadge("Some rules overlap", state: .warning)
                        SectionFooterNote(text: "Overlapping rules can both match the same host. The more specific rule wins.")

                        ForEach(conflicts) { conflict in
                            Text("- \(conflict.domainA) overlaps \(conflict.domainB)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
        }
    }

    @ViewBuilder
    private var advancedSection: some View {
        Section("Advanced") {
            DangerZoneView(
                title: "Reset compatibility overrides",
                message: "Clears \(appOverrideCount) app overrides and \(domainRows.count) domain rules."
            ) {
                Button("Reset All Compatibility Overrides", role: .destructive) {
                    isConfirmingOverrideReset = true
                }
                .disabled(overrides.isEmpty)
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
            .frame(width: 140)
            .help(newDomainMode.helpText)

            Button {
                addDomainRule()
            } label: {
                Image(systemName: "plus")
            }
            .help("Add domain rule")
            .disabled(DomainNormalization.canonicalDomainStringAllowingEmpty(from: domainText).isEmpty)
        }
    }

    private func domainRuleRow(_ row: DomainOverrideRow) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "globe")
                .frame(width: 32, height: 32)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text(row.domain)
                    .font(.headline)
                HStack(spacing: 6) {
                    StatusBadge("Domain rule", state: .warning)
                    StatusBadge(row.mode.title, state: SettingsVisualState.activation(row.mode))
                }
            }

            Spacer()

            CompatibilityModePicker(
                title: "Domain mode",
                selection: domainOptionalModeBinding(for: row.domain)
            )

            Button {
                setDomainMode(nil, for: row.domain)
            } label: {
                Image(systemName: "trash")
            }
            .help("Remove domain rule")
        }
        .padding(.vertical, 4)
    }

    private func appRow(_ app: InstalledApplication) -> some View {
        let decision = controller.compatibilityCatalog.decision(
            bundleID: app.bundleID,
            domain: nil,
            userModeOverrides: overrides
        )
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: app.icon)
                    .resizable()
                    .frame(width: 32, height: 32)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(app.displayName)
                        .font(.headline)
                    Text(app.bundleID)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 12)

                VStack(alignment: .trailing, spacing: 5) {
                    StatusBadge(CompatibilityPresentation.compatibilityTitle(for: decision.profile.status), state: SettingsVisualState.compatibility(decision.profile.status))
                        .fixedSize()
                    StatusBadge(CompatibilityPresentation.sourceTitle(for: decision.ruleSource), state: CompatibilityPresentation.sourceState(for: decision.ruleSource))
                        .fixedSize()
                    StatusBadge(decision.overrideMode.title, state: SettingsVisualState.activation(decision.overrideMode))
                        .fixedSize()
                }
            }

            HStack(spacing: 12) {
                LabeledContent("Default", value: decision.profile.defaultActivationMode.title)
                LabeledContent("Display", value: CompatibilityPresentation.displayModeTitle(for: decision.mode))
                Spacer(minLength: 8)
                CompatibilityModePicker(
                    title: "App mode",
                    selection: modeBinding(for: app.bundleID)
                )

                Button {
                    setMode(nil, for: app.bundleID)
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                }
                .help("Remove app override")
                .disabled(overrides[app.bundleID] == nil)
            }
            .font(.caption)

            if !decision.profile.notes.isEmpty {
                DisclosureGroup("Notes") {
                    SectionFooterNote(text: decision.profile.notes)
                }
            }
        }
        .padding(.vertical, 6)
    }

    private func modeBinding(for bundleID: String) -> Binding<CompatibilityOverrideMode?> {
        Binding {
            overrides[bundleID]
        } set: { mode in
            setMode(mode, for: bundleID)
        }
    }

    private func domainOptionalModeBinding(for domain: String) -> Binding<CompatibilityOverrideMode?> {
        Binding {
            overrides[CompatibilityCatalog.overrideKey(forDomain: domain)]
        } set: { mode in
            setDomainMode(mode, for: domain)
        }
    }

    private func addDomainRule() {
        let domain = DomainNormalization.canonicalDomainStringAllowingEmpty(from: domainText)
        guard !domain.isEmpty else {
            return
        }
        setDomainMode(newDomainMode, for: domain)
        domainText = ""
    }

    private func setDomainMode(_ mode: CompatibilityOverrideMode?, for domain: String) {
        let normalizedDomain = DomainNormalization.canonicalDomainStringAllowingEmpty(from: domain)
        let key = CompatibilityCatalog.overrideKey(forDomain: normalizedDomain)
        if let mode {
            overrides[key] = mode
        } else {
            overrides.removeValue(forKey: key)
        }
        controller.compatibilitySettings.setMode(mode, forDomain: normalizedDomain)
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

    private func revealApp(bundleID: String) {
        searchText = bundleID
    }

    private func reloadInstalledApps() {
        isScanningApps = true
        installedApps = InstalledApplicationScanner().scan()
        isScanningApps = false
    }

    private func domainsConflict(a: String, b: String) -> Bool {
        let hostA = DomainNormalization.canonicalDomainStringAllowingEmpty(from: a).split(separator: "/", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        let hostB = DomainNormalization.canonicalDomainStringAllowingEmpty(from: b).split(separator: "/", omittingEmptySubsequences: true).first.map(String.init) ?? ""
        guard !hostA.isEmpty, !hostB.isEmpty else {
            return false
        }

        if hostA == hostB {
            return true
        }

        if hostA.hasSuffix("." + hostB) || hostB.hasSuffix("." + hostA) {
            return true
        }

        return false
    }

    private struct DomainOverrideRow: Identifiable {
        let domain: String
        let mode: CompatibilityOverrideMode

        var id: String { domain }
    }

    private struct DomainRuleConflictRow: Identifiable {
        let domainA: String
        let domainB: String

        var id: String { "\(domainA)|\(domainB)" }
    }
}

private struct FocusedAppSection: View {
    @ObservedObject var focusTrackingModel: FocusTrackingModel
    let catalog: CompatibilityCatalog
    @Binding var overrides: [String: CompatibilityOverrideMode]
    let installedApps: [InstalledApplication]
    let setAppMode: (CompatibilityOverrideMode?, String) -> Void
    let setDomainMode: (CompatibilityOverrideMode?, String) -> Void
    let revealApp: (String) -> Void

    var body: some View {
        Section("Focused app") {
            if let snapshot = focusTrackingModel.snapshot {
                focusedAppCard(snapshot)
            } else {
                SettingsInfoCard(
                    title: "No focused app",
                    subtitle: "Focus a text field to inspect app compatibility.",
                    state: .pending,
                    statusTitle: "Waiting",
                    systemImage: "scope"
                ) {
                    SectionFooterNote(text: "The app card updates from the same focused-field snapshot used by Health.")
                }
            }
        }
    }

    private func focusedAppCard(_ snapshot: FocusTrackingSnapshot) -> some View {
        let context = snapshot.context
        let bundleID = context.app.bundleID
        let domain = context.domain
        let decision = catalog.decision(
            bundleID: bundleID,
            domain: domain,
            userModeOverrides: overrides
        )

        return SettingsInfoCard(
            title: context.app.displayName,
            subtitle: bundleID,
            state: SettingsVisualState.compatibility(decision.profile.status),
            statusTitle: CompatibilityPresentation.compatibilityTitle(for: decision.profile.status)
        ) {
            HStack(alignment: .top, spacing: 12) {
                Image(nsImage: icon(for: bundleID))
                    .resizable()
                    .frame(width: 36, height: 36)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 6) {
                    LabeledContent("Bundle ID", value: bundleID)
                    if let domain, !domain.isEmpty {
                        LabeledContent("Domain", value: domain)
                    }
                    LabeledContent("Rule source", value: CompatibilityPresentation.sourceTitle(for: decision.ruleSource))
                    LabeledContent("Effective mode", value: decision.overrideMode.title)
                    LabeledContent("Display", value: CompatibilityPresentation.displayModeTitle(for: decision.mode))
                    SectionFooterNote(text: CompatibilityPresentation.focusedReason(for: decision))
                }
            }

            HStack(spacing: 8) {
                CompatibilityModePicker(
                    title: "App mode",
                    selection: appModeBinding(for: bundleID)
                )

                Button("Find in List") {
                    revealApp(bundleID)
                }

                Button("Reset App Override") {
                    setAppMode(nil, bundleID)
                }
                .disabled(overrides[bundleID] == nil)
            }

            if let domain, !domain.isEmpty {
                HStack(spacing: 8) {
                    CompatibilityModePicker(
                        title: "Domain mode",
                        selection: domainModeBinding(for: domain)
                    )

                    Button("Reset Domain Rule") {
                        setDomainMode(nil, domain)
                    }
                    .disabled(overrides[CompatibilityCatalog.overrideKey(forDomain: domain)] == nil)
                }
            }
        }
    }

    private func appModeBinding(for bundleID: String) -> Binding<CompatibilityOverrideMode?> {
        Binding {
            overrides[bundleID]
        } set: { mode in
            setAppMode(mode, bundleID)
        }
    }

    private func domainModeBinding(for domain: String) -> Binding<CompatibilityOverrideMode?> {
        Binding {
            overrides[CompatibilityCatalog.overrideKey(forDomain: domain)]
        } set: { mode in
            setDomainMode(mode, domain)
        }
    }

    private func icon(for bundleID: String) -> NSImage {
        if let installedApp = installedApps.first(where: { $0.bundleID == bundleID }) {
            return installedApp.icon
        }

        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return NSWorkspace.shared.icon(forFile: url.path)
        }

        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage(size: NSSize(width: 32, height: 32))
    }
}

private struct CompatibilityModePicker: View {
    let title: String
    @Binding var selection: CompatibilityOverrideMode?

    var body: some View {
        Picker(title, selection: $selection) {
            Text("Default/catalog").tag(CompatibilityOverrideMode?.none)
            ForEach(CompatibilityOverrideMode.allCases) { mode in
                Text(mode.title).tag(Optional(mode))
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .frame(width: 150)
    }
}

private enum CompatibilityPresentation {
    static func compatibilityTitle(for status: CompatibilityStatus) -> String {
        switch status {
        case .works:
            return "Works"
        case .setupNeeded:
            return "Setup"
        case .partial:
            return "Partial"
        case .mirrorOnly:
            return "Mirror"
        case .unsupported:
            return "Unsupported"
        }
    }

    static func displayModeTitle(for mode: SuggestionDisplayMode) -> String {
        switch mode {
        case .inline:
            return "Inline"
        case .mirrorWindow:
            return "Mirror"
        case .disabled:
            return "Disabled"
        }
    }

    static func sourceTitle(for source: CompatibilityDecision.RuleSource) -> String {
        switch source {
        case .default:
            return "Catalog default"
        case .appRule:
            return "App override"
        case .domainRule:
            return "Domain rule"
        }
    }

    static func sourceState(for source: CompatibilityDecision.RuleSource) -> SettingsVisualState {
        switch source {
        case .default:
            return .pending
        case .appRule, .domainRule:
            return .warning
        }
    }

    static func focusedReason(for decision: CompatibilityDecision) -> String {
        if decision.profile.status == .unsupported {
            return decision.profile.notes.isEmpty ? "This app is currently unsupported." : decision.profile.notes
        }
        if decision.overrideMode == .disabled {
            return "Suggestions are off for this target."
        }
        if let warning = decision.warningMessage {
            return warning
        }
        if let setup = decision.setupMessage {
            return "Setup needed: \(setup)"
        }
        if decision.overrideMode == .manualOnly {
            return "Suggestions are available from the manual trigger only."
        }
        if !decision.profile.notes.isEmpty {
            return decision.profile.notes
        }
        return "Automatic suggestions can appear while you type."
    }
}
