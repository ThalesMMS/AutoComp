import AutoCompCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct DeveloperSettingsView: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var engine: SuggestionEngine
    @EnvironmentObject private var localRuntimeStatusStore: LocalLlamaRuntimeStatusStore
    @State private var debugOptions = AutoCompDebugOptions()
    @State private var debugArtifactCount = 0
    @State private var debugArtifactMessage: String?
    @State private var settingsTransferMessage: String?
    @State private var pendingSettingsImportPreview: RedactedSettingsImportPreview?
    @State private var developerMessage: String?
    @State private var isConfirmingDebugArtifactDeletion = false
    @State private var isConfirmingSettingsImport = false

    var body: some View {
        SettingsPaneForm(title: "Developer") {
            Section("Debug") {
                Toggle("Enable local debug artifacts and prompt previews", isOn: debugOptInBinding)
                SectionFooterNote(text: "When enabled, AutoComp may save prompts, OCR, clipboard context, or typed text to local debug artifacts. Leave this off unless actively debugging.")
                LabeledContent("Debug artifacts", value: "\(debugArtifactCount)")
                LabeledContent("Location", value: controller.debugArtifactDirectoryPath)
                Button("Export Debug Logs...") {
                    exportDebugLogs()
                }
                DangerZoneView(
                    title: "Delete debug artifacts",
                    message: "Removes local debug bundles and prompt previews from this Mac."
                ) {
                    Button("Delete Debug Artifacts", role: .destructive) {
                        isConfirmingDebugArtifactDeletion = true
                    }
                }
                if let debugArtifactMessage {
                    StatusBadge(debugArtifactMessage, state: messageVisualState(debugArtifactMessage))
                }
            }

            Section("Settings transfer") {
                SectionFooterNote(text: "Redacted exports exclude API keys, local model paths, debug artifacts, prompt previews, and local file paths. Writing preferences are included.")
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
                    StatusBadge(settingsTransferMessage, state: messageVisualState(settingsTransferMessage))
                }
            }

            Section("Diagnostic launch flags") {
                SettingsActionRow(
                    title: "Focus debug overlay",
                    subtitle: "Draws focus, caret, glyph, and OCR rectangles after relaunch with the debug flag.",
                    state: debugFlagState(FocusDebugOverlayOptions().isEnabled),
                    statusTitle: enabledTitle(FocusDebugOverlayOptions().isEnabled)
                )
                SettingsActionRow(
                    title: "Geometry debug logging",
                    subtitle: "Writes redacted overlay and geometry decisions to stderr and the app logger.",
                    state: debugFlagState(GeometryDebug.isEnabled),
                    statusTitle: enabledTitle(GeometryDebug.isEnabled)
                )
                SettingsActionRow(
                    title: "Refresh debug logging",
                    subtitle: "Writes redacted refresh and eligibility decisions to stderr and the app logger.",
                    state: debugFlagState(RefreshDiagnostics.isEnabled),
                    statusTitle: enabledTitle(RefreshDiagnostics.isEnabled)
                )
                HStack {
                    Button("Copy Focus Overlay Flag") {
                        copyLaunchSnippet("--focus-debug-overlay")
                    }
                    Button("Copy Geometry Debug Env") {
                        copyLaunchSnippet("AUTOCOMP_GEOMETRY_DEBUG=1 AUTOCOMP_REFRESH_DEBUG=1")
                    }
                }
                if let developerMessage {
                    StatusBadge(developerMessage, state: .ok)
                }
            }

            Section("Overlay recovery") {
                SettingsActionRow(
                    title: "Safe overlay mode",
                    subtitle: controller.overlayRecoveryAdvisor.recommendationMessage,
                    state: safeOverlayState,
                    statusTitle: controller.overlayRecoveryAdvisor.safeModeStatusTitle
                )
                OverlayRecoveryRecommendationView(advisor: controller.overlayRecoveryAdvisor)
                Button("Copy Safe Overlay Launch") {
                    copyLaunchSnippet("\(SafeOverlayMode.environmentKey)=1")
                }
            }

            Section("Backend diagnostics") {
                let activeSettings = controller.completionBackendSettings
                let activeSurface = BackendSurface(settings: activeSettings, diagnostics: engine.diagnostics)
                SettingsActionRow(
                    title: "Backend state",
                    state: SettingsVisualState.backend(engine.backendStatusSummary.state),
                    statusTitle: engine.backendStatusSummary.menuTitle
                )
                LabeledContent("Active engine", value: activeSettings.engineKind.displayName)
                LabeledContent("Request destination", value: activeSurface.requestDestinationTitle)
                LabeledContent("Requested backend", value: engine.diagnostics.backend.requestedKind?.displayName ?? "None yet")
                LabeledContent("Delivered backend", value: engine.diagnostics.backend.deliveredKind?.displayName ?? "None yet")
                LabeledContent("Last backend used", value: engine.diagnostics.backend.lastUsedTitle)
                LabeledContent(
                    "Last local error",
                    value: engine.diagnostics.backend.errorTitle(
                        for: .localLlama,
                        storedLocalError: activeSettings.localLastError
                    )
                )
                LabeledContent("Last Apple error", value: engine.diagnostics.backend.errorTitle(for: .appleIntelligence))
                LabeledContent("Last remote error", value: engine.diagnostics.backend.errorTitle(for: .remote))
            }

            Section("Local runtime diagnostics") {
                let activeSettings = controller.completionBackendSettings
                let diagnostic = BackendSurface(
                    settings: activeSettings,
                    localLoadStatus: localRuntimeStatusStore.status
                ).localRuntimeDiagnostic
                LabeledContent("Bootstrap", value: activeSettings.localRuntimeState.message)
                LabeledContent("Runtime", value: diagnostic.runtimeTitle)
                LabeledContent("Model file", value: diagnostic.modelFileTitle)
                LabeledContent("Load state", value: diagnostic.loadStateTitle)
                LabeledContent("Last error", value: diagnostic.lastErrorTitle)
                LabeledContent("Fallback", value: diagnostic.fallbackTitle)
                LabeledContent("Memory limit", value: diagnostic.memoryLimitTitle)
                DisclosureGroup("Runtime details") {
                    SectionFooterNote(text: "Local in-process completion is usable only when this build includes the runtime and the model file exists.")
                }
            }

            Section("Apple Intelligence diagnostics") {
                let activeSettings = controller.completionBackendSettings
                let diagnostic = BackendSurface(settings: activeSettings).appleIntelligenceAvailabilityDiagnostic
                LabeledContent("Availability", value: diagnostic.availabilityTitle)
                LabeledContent("Requirement", value: diagnostic.requirementTitle)
                LabeledContent("Fallback", value: diagnostic.fallbackTitle)
                SectionFooterNote(text: "Apple Intelligence requires FoundationModels in the build SDK and a supported macOS release.")
            }

            Section("Focus and geometry") {
                if let focus = engine.diagnostics.focus {
                    LabeledContent("Focused app", value: focus.appDisplayName)
                    LabeledContent("Bundle ID", value: focus.bundleID)
                    LabeledContent("Domain", value: focus.domain ?? "None")
                    LabeledContent("Focused element ID", value: focus.focusedElementID ?? "None")
                    LabeledContent("Context source", value: focus.contextSource)
                    LabeledContent("Geometry quality", value: focus.geometryQuality)
                    LabeledContent("Context trust", value: focus.contextTrust)
                    LabeledContent("Caret rect", value: focus.hasCaretRect ? "Available" : "Missing")
                    LabeledContent("Focused element rect", value: focus.hasFocusedElementRect ? "Available" : "Missing")
                    if let warning = focus.contextWarning {
                        StatusBadge(warning, state: .warning)
                    }
                } else {
                    LabeledContent("Focus status", value: engine.diagnostics.focusFailure?.status.rawValue ?? "Readable or idle")
                    SectionFooterNote(text: engine.diagnostics.focusFailure?.action ?? "Focus a text field to populate focus diagnostics.")
                }
                LabeledContent("Input method", value: engine.diagnostics.inputMethod.summary)
                LabeledContent("Input source ID", value: engine.diagnostics.inputMethod.inputSourceID ?? "Not captured")
            }

            Section("Prompt, output, and latency") {
                LabeledContent("Raw output summary", value: engine.diagnostics.output.rawPreview ?? "None")
                LabeledContent("Normalized output summary", value: engine.diagnostics.output.normalizedPreview ?? "None")
                LabeledContent("Prompt cache", value: engine.diagnostics.promptCache?.summary ?? "No sample")
                if let redactedLatencyReport = engine.diagnostics.redactedLatencyReport() {
                    Text("Latency breakdown")
                        .font(.caption.weight(.medium))
                    Text(redactedLatencyReport)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                } else {
                    SectionFooterNote(text: "No latency report yet.")
                }
                SectionFooterNote(text: "Prompt and output content is shown only as redacted summaries unless local debug artifacts are explicitly enabled.")
            }

            Section("AX capability snapshots") {
                SettingsActionRow(
                    title: "Snapshot recorder",
                    subtitle: "Captures redacted AX capability and geometry metadata for fixture work after relaunch.",
                    state: debugFlagState(isAXCapabilitySnapshotEnabled),
                    statusTitle: enabledTitle(isAXCapabilitySnapshotEnabled)
                )
                Button("Copy AX Snapshot Env") {
                    copyLaunchSnippet("AUTOCOMP_CAPTURE_AX_CAPABILITY_SNAPSHOT=1")
                }
                SectionFooterNote(text: "Snapshots are written as redacted local debug artifacts and do not include focused text.")
            }

            Section("Runtime diagnostics") {
                if engine.diagnostics.menuRows.isEmpty {
                    SectionFooterNote(text: "Runtime diagnostics appear after AutoComp observes focus, input, or backend activity.")
                } else {
                    ForEach(engine.diagnostics.menuRows) { row in
                        LabeledContent(row.title, value: row.value)
                    }
                }
            }
        }
        .onAppear {
            reloadDebugState()
        }
        .confirmationDialog(
            "Delete Debug Artifacts?",
            isPresented: $isConfirmingDebugArtifactDeletion,
            titleVisibility: .visible
        ) {
            Button("Delete Debug Artifacts", role: .destructive) {
                deleteDebugArtifacts()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes local debug bundles and prompt previews from this Mac.")
        }
        .confirmationDialog(
            "Apply Redacted Settings Import?",
            isPresented: $isConfirmingSettingsImport,
            titleVisibility: .visible
        ) {
            Button("Apply Import", role: .destructive) {
                if let pendingSettingsImportPreview {
                    applyRedactedSettingsImport(pendingSettingsImportPreview)
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This updates local settings from the redacted import preview. API keys and local paths are not included in redacted exports.")
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

    private var safeOverlayState: SettingsVisualState {
        if SafeOverlayMode.isEnabled {
            return .ok
        }
        return controller.overlayRecoveryAdvisor.shouldRecommendSafeOverlayMode ? .warning : .disabled
    }

    private var isAXCapabilitySnapshotEnabled: Bool {
        ProcessInfo.processInfo.environment["AUTOCOMP_CAPTURE_AX_CAPABILITY_SNAPSHOT"] == "1"
    }

    private func reloadDebugState() {
        debugOptions = controller.debugOptions()
        debugArtifactCount = controller.debugArtifactCount()
    }

    private func messageVisualState(_ message: String) -> SettingsVisualState {
        message.localizedCaseInsensitiveContains("unable") ? .error : .ok
    }

    private func debugFlagState(_ enabled: Bool) -> SettingsVisualState {
        enabled ? .ok : .disabled
    }

    private func enabledTitle(_ enabled: Bool) -> String {
        enabled ? "Active" : "Off"
    }

    private func copyLaunchSnippet(_ snippet: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snippet, forType: .string)
        developerMessage = "Copied: \(snippet)"
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
        controller.withInteractionPipelineSuspended(reason: .settingsExport) {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Export"
            panel.message = "Choose where to save the local debug log export."

            let response = controller.withInteractionPipelineSuspended(reason: .openPanel) {
                panel.runModal()
            }
            guard response == .OK, let directory = panel.url else {
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
    }

    private func exportRedactedSettings() {
        controller.withInteractionPipelineSuspended(reason: .settingsExport) {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.json]
            panel.canCreateDirectories = true
            panel.nameFieldStringValue = controller.redactedSettingsExportFilename()
            panel.prompt = "Export"
            panel.message = "Choose where to save the redacted settings export."

            let response = controller.withInteractionPipelineSuspended(reason: .openPanel) {
                panel.runModal()
            }
            guard response == .OK, let url = panel.url else {
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
    }

    private func importRedactedSettings() {
        controller.withInteractionPipelineSuspended(reason: .settingsImport) {
            let panel = NSOpenPanel()
            panel.canChooseFiles = true
            panel.canChooseDirectories = false
            panel.allowsMultipleSelection = false
            panel.allowedContentTypes = [.json]
            panel.prompt = "Import"
            panel.message = "Choose a redacted settings export."

            let response = controller.withInteractionPipelineSuspended(reason: .openPanel) {
                panel.runModal()
            }
            guard response == .OK, let url = panel.url else {
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
    }

    private func applyRedactedSettingsImport(_ preview: RedactedSettingsImportPreview) {
        controller.withInteractionPipelineSuspended(reason: .settingsImport) {
            do {
                try controller.applyRedactedSettingsImport(preview)
                pendingSettingsImportPreview = nil
                settingsTransferMessage = "Redacted settings imported."
            } catch {
                settingsTransferMessage = "Unable to apply redacted settings: \(error.localizedDescription)"
            }
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
                    isConfirmingSettingsImport = true
                }
                Button("Cancel Import", role: .cancel) {
                    pendingSettingsImportPreview = nil
                    settingsTransferMessage = "Redacted settings import canceled."
                }
            }
        }
    }
}
