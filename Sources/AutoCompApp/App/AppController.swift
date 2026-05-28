import AppKit
import Combine
import AutoCompCore
import Foundation
import SwiftUI

@MainActor
final class AppController: ObservableObject {
    private static let settingsWindowMinimumContentSize = NSSize(width: 880, height: 560)

    @Published var selectedSettingsSection: SettingsSection = .permissions
    @Published private(set) var completionBackendSummary: String
    @Published var completionBackendSettings: CompletionBackendSettings

    let permissionService: PermissionService
    let compatibilityCatalog: CompatibilityCatalog
    let compatibilitySettings: CompatibilitySettingsStore
    let privacySettingsStore: PrivacySettingsStore
    let personalizationStore: SecurePersonalizationStore
    let focusTrackingModel: FocusTrackingModel
    let suggestionEngine: SuggestionEngine
    let shortcutSettingsStore: KeyboardShortcutSettingsStore
    let remoteCompletionConsentStore: RemoteCompletionConsentStore
    let localLlamaRuntimeStatusStore: LocalLlamaRuntimeStatusStore
    let debugOptionsStore: AutoCompDebugOptionsStore
    let overlayRecoveryAdvisor: OverlayRecoveryAdvisor
    let productivityMetricsStore: LocalProductivityMetricsStore
    let installationLocationService: InstallationLocationService

    private let environment: AutoCompAppEnvironment
    private let acceptanceService: AcceptanceService
    private let keyboardShortcuts: KeyboardShortcutService
    private let completionBackendConfigurationService: CompletionBackendConfigurationService
    private let completionPlaygroundService = CompletionPlaygroundService()
    private let debugArtifactStore: DebugArtifactStore
    private let suggestionDebugLogger: SuggestionDebugLogger
    private let localPrivacyDataResetService: LocalPrivacyDataResetService
    private let telemetryClient: any TelemetryClient
    private let settingsWindowResizeDelegate = MinimumContentSizeWindowDelegate(
        minContentSize: AppController.settingsWindowMinimumContentSize
    )
    private let usesInlinePreviewTestProvider: Bool
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    convenience init() {
        self.init(environment: AutoCompAppEnvironment())
    }

    init(environment: AutoCompAppEnvironment) {
        self.environment = environment
        self.permissionService = environment.permissionService
        self.compatibilityCatalog = environment.compatibilityCatalog
        self.compatibilitySettings = environment.compatibilitySettings
        self.privacySettingsStore = environment.privacySettingsStore
        self.personalizationStore = environment.personalizationStore
        self.focusTrackingModel = environment.focusTrackingModel
        self.suggestionEngine = environment.suggestionEngine
        self.shortcutSettingsStore = environment.shortcutSettingsStore
        self.remoteCompletionConsentStore = environment.remoteCompletionConsentStore
        self.localLlamaRuntimeStatusStore = environment.localLlamaRuntimeStatusStore
        self.debugOptionsStore = environment.debugOptionsStore
        self.overlayRecoveryAdvisor = environment.overlayRecoveryAdvisor
        self.productivityMetricsStore = environment.productivityMetricsStore
        self.acceptanceService = environment.acceptanceService
        self.keyboardShortcuts = environment.keyboardShortcuts
        self.completionBackendConfigurationService = environment.completionBackendConfigurationService
        self.debugArtifactStore = environment.debugArtifactStore
        self.suggestionDebugLogger = environment.suggestionDebugLogger
        self.localPrivacyDataResetService = LocalPrivacyDataResetService(
            personalizationStore: environment.personalizationStore,
            privacySettingsStore: environment.privacySettingsStore,
            productivityMetricsStore: environment.productivityMetricsStore,
            telemetryClient: environment.telemetryClient,
            remoteCompletionConsentStore: environment.remoteCompletionConsentStore,
            debugOptionsStore: environment.debugOptionsStore,
            debugArtifactStore: environment.debugArtifactStore,
            pasteboardRecoveryStore: environment.pasteboardRecoveryStore
        )
        self.installationLocationService = environment.installationLocationService
        self.telemetryClient = environment.telemetryClient
        self.usesInlinePreviewTestProvider = environment.usesInlinePreviewTestProvider
        self.completionBackendSettings = environment.initialCompletionBackendSettings
        self.completionBackendSummary = environment.initialCompletionBackendSettings.summary

        permissionService.$inputMonitoringAllowed
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                self?.startKeyboardShortcuts()
            }
            .store(in: &cancellables)

        Task { @MainActor [weak self] in
            self?.start()
            self?.openRequestedDebugWindowIfNeeded()
        }
    }

    func start() {
        installationLocationService.refresh()
        permissionService.startMonitoring()
        permissionService.refresh()
        acceptanceService.recoverPendingPasteboardInsertionIfNeeded()
        refreshCompletionBackendSettings()
        suggestionEngine.start()
        startKeyboardShortcuts()
    }

    private func startKeyboardShortcuts() {
        keyboardShortcuts.start(
            onCommand: { [weak self] command in
                Task { @MainActor in
                    await self?.handleShortcutCommand(command)
                }
            },
            onInputEvent: { [weak self] event in
                Task { @MainActor in
                    self?.suggestionEngine.recordCapturedInputEvent(event)
                }
            },
            shouldInterceptCommand: { [weak self] command in
                switch command {
                case .selectPreviousSuggestion, .selectNextSuggestion:
                    return self?.suggestionEngine.isMultiSuggestionPopupVisible == true
                case .acceptNextWord, .acceptFullSuggestion, .manualTrigger, .dismissSuggestion, .toggleAutocomplete:
                    return true
                }
            }
        )
    }

    private func handleShortcutCommand(_ command: KeyboardShortcutCommand) async {
        switch command {
        case .acceptNextWord:
            let outcome = await suggestionEngine.acceptNextWord(using: acceptanceService)
            syncShortcutStateAfterAcceptance()
            if outcome == .passedThrough {
                keyboardShortcuts.replayPassthroughShortcut(command)
            }
        case .acceptFullSuggestion:
            await suggestionEngine.acceptAll(using: acceptanceService)
            syncShortcutStateAfterAcceptance()
        case .selectPreviousSuggestion:
            suggestionEngine.selectPreviousAlternative()
            syncShortcutStateAfterAcceptance()
        case .selectNextSuggestion:
            suggestionEngine.selectNextAlternative()
            syncShortcutStateAfterAcceptance()
        case .manualTrigger:
            await suggestionEngine.triggerManualSuggestion()
            syncShortcutStateAfterAcceptance()
        case .dismissSuggestion:
            suggestionEngine.dismissSuggestionUntilTextMutation()
            syncShortcutStateAfterAcceptance()
        case .toggleAutocomplete:
            toggleAutocompleteEnabled()
        }
    }

    private func syncShortcutStateAfterAcceptance() {
        let hasSuggestion = suggestionEngine.isAutocompleteEnabled && suggestionEngine.currentSuggestion != nil
        keyboardShortcuts.setSuggestionActive(hasSuggestion)
        if !hasSuggestion {
            keyboardShortcuts.clearShortcutGrace()
        }
    }

    func toggleAutocompleteEnabled() {
        suggestionEngine.setAutocompleteEnabled(!suggestionEngine.isAutocompleteEnabled)
        syncShortcutStateAfterAcceptance()
    }

    func saveKeyboardShortcutSettings(_ settings: KeyboardShortcutSettings) {
        shortcutSettingsStore.save(settings)
        keyboardShortcuts.updateShortcutSettings(settings)
    }

    func stop() {
        suggestionEngine.stop()
        keyboardShortcuts.stop()
        permissionService.stopMonitoring()
    }

    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            guard error == nil else { return }
            Task { @MainActor in
                NSApp.terminate(nil)
            }
        }
    }

    func deletePersonalizationData() {
        try? personalizationStore.deleteAll()
        try? privacySettingsStore.resetWritingPreferences()
    }

    func deleteAllLocalPrivacyData() throws {
        try localPrivacyDataResetService.deleteAllLocalPrivacyData()
    }

    func savePrivacySettings(_ settings: PrivacySettings) {
        try? privacySettingsStore.save(settings)
        telemetryClient.setEnabled(false)
        productivityMetricsStore.reload()
    }

    func resetProductivityMetrics() {
        productivityMetricsStore.reset()
    }

    func saveDebugOptions(_ options: AutoCompDebugOptions) {
        debugOptionsStore.save(options)
    }

    func debugOptions() -> AutoCompDebugOptions {
        debugOptionsStore.load()
    }

    func hasRemoteCompletionConsent(
        for scope: RemoteCompletionConsentScope,
        settings: CompletionBackendSettings
    ) -> Bool {
        remoteCompletionConsentStore.hasConsent(
            for: scope,
            remoteBaseURL: settings.remoteBaseURL
        )
    }

    func grantRemoteCompletionConsent(
        for scope: RemoteCompletionConsentScope,
        settings: CompletionBackendSettings
    ) {
        remoteCompletionConsentStore.grantConsent(
            for: scope,
            remoteBaseURL: settings.remoteBaseURL
        )
    }

    func resetRemoteCompletionConsent() {
        remoteCompletionConsentStore.reset()
    }

    func deleteDebugArtifacts() throws {
        try debugArtifactStore.deleteAll()
    }

    func exportDebugLogs(to directory: URL) throws -> URL {
        try debugArtifactStore.exportDebugLogs(
            to: directory,
            options: debugOptions()
        )
    }

    func redactedSettingsExportFilename(now: Date = Date()) -> String {
        RedactedSettingsTransfer.exportFilename(now: now)
    }

    func exportRedactedSettings(to url: URL) throws {
        let package = RedactedSettingsTransfer.package(
            compatibilityOverrides: compatibilitySettings.loadModeOverrides(),
            privacySettings: privacySettingsStore.load(),
            shortcutSettings: shortcutSettingsStore.load(),
            backendSettings: completionBackendSettings,
            safeOverlayModeEnabled: SafeOverlayMode.isEnabled
        )
        let data = try RedactedSettingsTransfer.encodedData(for: package)
        try data.write(to: url, options: [.atomic])
    }

    func redactedSettingsImportPreview(from data: Data) throws -> RedactedSettingsImportPreview {
        let package = try RedactedSettingsTransfer.decodedPackage(from: data)
        return RedactedSettingsTransfer.preview(
            package: package,
            currentCompatibilityOverrides: compatibilitySettings.loadModeOverrides(),
            currentPrivacySettings: privacySettingsStore.load(),
            currentShortcutSettings: shortcutSettingsStore.load(),
            currentBackendSettings: completionBackendSettings,
            safeOverlayModeEnabled: SafeOverlayMode.isEnabled
        )
    }

    func applyRedactedSettingsImport(_ preview: RedactedSettingsImportPreview) throws {
        let package = preview.package
        compatibilitySettings.resetOverrides()
        for (bundleID, mode) in package.compatibility.appOverrides {
            compatibilitySettings.setMode(mode, for: bundleID)
        }
        for (domain, mode) in package.compatibility.domainOverrides {
            compatibilitySettings.setMode(mode, forDomain: domain)
        }

        let updatedPrivacySettings = RedactedSettingsTransfer.privacySettings(
            applying: package.privacy,
            to: privacySettingsStore.load()
        )
        try privacySettingsStore.save(updatedPrivacySettings)
        telemetryClient.setEnabled(false)
        productivityMetricsStore.reload()

        saveKeyboardShortcutSettings(package.shortcuts)

        let updatedBackendSettings = RedactedSettingsTransfer.backendSettings(
            applying: package.backend,
            to: completionBackendSettings
        )
        saveCompletionBackendSettings(updatedBackendSettings)
    }

    func debugArtifactCount() -> Int {
        debugArtifactStore.artifactCount()
    }

    var debugArtifactDirectoryPath: String {
        debugArtifactStore.directoryPath
    }

    func refreshCompletionBackendSettings() {
        guard !usesInlinePreviewTestProvider else {
            return
        }
        completionBackendSettings = completionBackendConfigurationService.load()
        completionBackendSummary = completionBackendSettings.summary
    }

    func saveCompletionBackendSettings(_ settings: CompletionBackendSettings) {
        let switchReason = completionProviderSwitchReason(from: completionBackendSettings, to: settings)
        completionBackendConfigurationService.save(settings)
        completionBackendSettings = settings
        completionBackendSummary = settings.summary
        suggestionEngine.updateMultiSuggestionEnabled(settings.multiSuggestionEnabled)
        suggestionEngine.updateCompletionProvider(
            environment.completionProvider(for: settings),
            status: "Completion backend updated",
            reason: switchReason
        )
    }

    func unloadLocalLlamaRuntime() {
        localLlamaRuntimeStatusStore.record(LocalLlamaRuntimeStatus(
            state: .unloaded,
            modelPath: completionBackendSettings.localModelPath
        ))
        suggestionEngine.updateCompletionProvider(
            environment.completionProvider(for: completionBackendSettings),
            status: "Local Llama unloaded",
            reason: .runtimeModelSwitch
        )
    }

    private func completionProviderSwitchReason(
        from previous: CompletionBackendSettings,
        to next: CompletionBackendSettings
    ) -> CompletionProviderSwitchReason {
        guard previous.engineKind == .localLlama,
              next.engineKind == .localLlama,
              previous.localConfiguration != next.localConfiguration else {
            return .backendSwitch
        }
        return .runtimeModelSwitch
    }

    func testRemoteConnection(settings: CompletionBackendSettings) async -> RemoteBackendProbeResult {
        let result = await RemoteBackendProbe().testConnection(configuration: settings.remoteConfiguration)
        suggestionEngine.recordBackendProbeResult(result)
        recordRemoteProbeTelemetry(result, settings: settings)
        return result
    }

    private func recordRemoteProbeTelemetry(
        _ result: RemoteBackendProbeResult,
        settings: CompletionBackendSettings
    ) {
        guard result.status == .failed else {
            return
        }

        telemetryClient.capture(TelemetryEventInput(
            name: "remote-backend-probe-failed",
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            buildNumber: Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown",
            backendKind: settings.engineKind,
            technicalError: TelemetryTechnicalError(
                category: "remote-backend-probe",
                code: result.issue?.logValue ?? "unknown"
            ),
            permissionStatuses: [
                .accessibility: permissionService.accessibilityTrusted ? .granted : .denied,
                .inputMonitoring: permissionService.inputMonitoringAllowed ? .granted : .denied,
                .screenRecording: permissionService.screenRecordingAllowed ? .granted : .denied
            ],
            bundleID: permissionService.runtimeBundleID
        ))
    }

    var isPlaygroundUITestMode: Bool {
        environment.usesPlaygroundTestProvider
    }

    func playgroundPreview(
        prefix: String,
        suffix: String,
        settings: CompletionBackendSettings
    ) -> CompletionPlaygroundPreview {
        completionPlaygroundService.preview(prefix: prefix, suffix: suffix, settings: settings)
    }

    func completePlayground(
        prefix: String,
        suffix: String,
        settings: CompletionBackendSettings
    ) async throws -> CompletionPlaygroundResult {
        let result = try await completionPlaygroundService.complete(
            prefix: prefix,
            suffix: suffix,
            settings: settings,
            provider: environment.playgroundCompletionProvider(for: settings)
        )
        suggestionDebugLogger.recordPlaygroundResult(result, options: debugOptionsStore.load())
        return result
    }

    func showOnboardingWindow() {
        let window = onboardingWindow ?? makeWindow(
            title: "AutoComp Onboarding",
            size: NSSize(width: 560, height: 500),
            content: OnboardingView()
                .environmentObject(self)
                .environmentObject(permissionService)
        )
        onboardingWindow = window
        show(window)
    }

    func showSettingsWindow() {
        let settingsWindowSize = Self.settingsWindowMinimumContentSize
        let window = settingsWindow ?? makeWindow(
            title: "AutoComp Settings",
            size: settingsWindowSize,
            minSize: settingsWindowSize,
            content: SettingsRootView()
                .environmentObject(self)
                .environmentObject(permissionService)
                .environmentObject(suggestionEngine)
                .environmentObject(localLlamaRuntimeStatusStore)
        )
        window.delegate = settingsWindowResizeDelegate
        settingsWindow = window
        show(window)
    }

    private func makeWindow<Content: View>(
        title: String,
        size: NSSize,
        minSize: NSSize? = nil,
        content: Content
    ) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
        if let minSize {
            window.minSize = minSize
            window.contentMinSize = minSize
        }
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        return window
    }

    private func show(_ window: NSWindow) {
        NSApp.setActivationPolicy(.regular)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func openRequestedDebugWindowIfNeeded() {
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--ui-test-settings") {
            selectedSettingsSection = .model
            showSettingsWindow()
        } else if arguments.contains("--ui-test-playground") {
            selectedSettingsSection = .model
            showSettingsWindow()
        } else if arguments.contains("--ui-test-onboarding") {
            showOnboardingWindow()
        }
    }
}

enum SettingsSection: String, CaseIterable, Identifiable {
    case permissions = "Permissions"
    case apps = "Apps"
    case privacy = "Privacy"
    case shortcuts = "Shortcuts"
    case model = "Model"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .permissions:
            return "lock.shield"
        case .apps:
            return "rectangle.stack"
        case .privacy:
            return "hand.raised"
        case .shortcuts:
            return "keyboard"
        case .model:
            return "cpu"
        }
    }
}

private final class MinimumContentSizeWindowDelegate: NSObject, NSWindowDelegate {
    private let minContentSize: NSSize

    init(minContentSize: NSSize) {
        self.minContentSize = minContentSize
    }

    func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        let minFrameSize = sender.frameRect(forContentRect: NSRect(origin: .zero, size: minContentSize)).size
        return NSSize(
            width: max(frameSize.width, minFrameSize.width),
            height: max(frameSize.height, minFrameSize.height)
        )
    }
}
