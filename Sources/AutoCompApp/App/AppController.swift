import AppKit
import Combine
import AutoCompCore
import Foundation
import SwiftUI

@MainActor
final class AppController: ObservableObject {
    private static let onboardingWindowContentSize = NSSize(width: 560, height: 560)
    private static let onboardingWindowMinimumContentSize = NSSize(width: 520, height: 440)
    private static let onboardingWindowMaximumContentSize = NSSize(width: 680, height: 600)
    private static let settingsWindowMinimumContentSize = NSSize(width: 880, height: 560)

    @Published var selectedSettingsSection: SettingsSection = .general
    @Published private(set) var completionBackendSummary: String
    @Published var completionBackendSettings: CompletionBackendSettings

    let permissionService: PermissionService
    let permissionGuidanceController: PermissionGuidanceController
    let compatibilityCatalog: CompatibilityCatalog
    let compatibilitySettings: CompatibilitySettingsStore
    let privacySettingsStore: PrivacySettingsStore
    let personalizationStore: SecurePersonalizationStore
    let focusTrackingModel: FocusTrackingModel
    let suggestionEngine: SuggestionEngine
    let interactionPipelineSuspensionController: InteractionPipelineSuspensionController
    let shortcutSettingsStore: KeyboardShortcutSettingsStore
    let healthSnapshotService: HealthSnapshotService
    let remoteCompletionConsentStore: RemoteCompletionConsentStore
    let localLlamaRuntimeStatusStore: LocalLlamaRuntimeStatusStore
    let debugOptionsStore: AutoCompDebugOptionsStore
    let overlayRecoveryAdvisor: OverlayRecoveryAdvisor
    let productivityMetricsStore: LocalProductivityMetricsStore
    let installationLocationService: InstallationLocationService

    private let environment: AutoCompAppEnvironment
    private let acceptanceService: AcceptanceService
    private let keyboardShortcuts: KeyboardShortcutService
    private let emojiVariantPreferencesStore: EmojiVariantPreferencesStore
    private let emojiPickerController: EmojiPickerController
    private let macroPreferencesStore: MacroPreferencesStore
    private let macroCommandController: MacroCommandController
    private let inlineCommandCoordinator: InlineCommandCoordinator
    private let completionBackendConfigurationService: CompletionBackendConfigurationService
    private let completionPlaygroundService = CompletionPlaygroundService()
    private let debugArtifactStore: DebugArtifactStore
    private let completionTraceStore: CompletionTraceStore
    private let suggestionDebugLogger: SuggestionDebugLogger
    private let localPrivacyDataResetService: LocalPrivacyDataResetService
    private let activationPolicyController: AppActivationPolicyController
    private let settingsWindowResizeDelegate = MinimumContentSizeWindowDelegate(
        minContentSize: AppController.settingsWindowMinimumContentSize
    )
    private let usesInlinePreviewTestProvider: Bool
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []
    private var windowCloseObserver: NSObjectProtocol?
    private var pipelineSuspensionHandlerID: UUID?
    private var hasStarted = false

    enum DebugLogExportResult {
        case cancelled
        case exported(URL)
        case failed(Error)
    }

    convenience init() {
        self.init(environment: AutoCompAppEnvironment())
    }

    init(environment: AutoCompAppEnvironment) {
        self.environment = environment
        self.permissionService = environment.permissionService
        self.permissionGuidanceController = environment.permissionGuidanceController
        self.compatibilityCatalog = environment.compatibilityCatalog
        self.compatibilitySettings = environment.compatibilitySettings
        self.privacySettingsStore = environment.privacySettingsStore
        self.personalizationStore = environment.personalizationStore
        self.focusTrackingModel = environment.focusTrackingModel
        self.suggestionEngine = environment.suggestionEngine
        self.interactionPipelineSuspensionController = environment.interactionPipelineSuspensionController
        self.shortcutSettingsStore = environment.shortcutSettingsStore
        self.healthSnapshotService = environment.healthSnapshotService
        self.remoteCompletionConsentStore = environment.remoteCompletionConsentStore
        self.localLlamaRuntimeStatusStore = environment.localLlamaRuntimeStatusStore
        self.debugOptionsStore = environment.debugOptionsStore
        self.overlayRecoveryAdvisor = environment.overlayRecoveryAdvisor
        self.productivityMetricsStore = environment.productivityMetricsStore
        self.acceptanceService = environment.acceptanceService
        self.keyboardShortcuts = environment.keyboardShortcuts
        self.emojiVariantPreferencesStore = environment.emojiVariantPreferencesStore
        self.emojiPickerController = environment.emojiPickerController
        self.macroPreferencesStore = environment.macroPreferencesStore
        self.macroCommandController = environment.macroCommandController
        self.inlineCommandCoordinator = environment.inlineCommandCoordinator
        self.completionBackendConfigurationService = environment.completionBackendConfigurationService
        self.debugArtifactStore = environment.debugArtifactStore
        self.completionTraceStore = environment.completionTraceStore
        self.suggestionDebugLogger = environment.suggestionDebugLogger
        self.localPrivacyDataResetService = LocalPrivacyDataResetService(
            personalizationStore: environment.personalizationStore,
            privacySettingsStore: environment.privacySettingsStore,
            productivityMetricsStore: environment.productivityMetricsStore,
            remoteCompletionConsentStore: environment.remoteCompletionConsentStore,
            debugOptionsStore: environment.debugOptionsStore,
            debugArtifactStore: environment.debugArtifactStore,
            completionTraceStore: environment.completionTraceStore,
            pasteboardRecoveryStore: environment.pasteboardRecoveryStore
        )
        self.installationLocationService = environment.installationLocationService
        self.activationPolicyController = AppActivationPolicyController()
        self.usesInlinePreviewTestProvider = environment.usesInlinePreviewTestProvider
        self.completionBackendSettings = environment.initialCompletionBackendSettings
        self.completionBackendSummary = BackendSurface(settings: environment.initialCompletionBackendSettings).summary

        permissionService.$inputMonitoringAllowed
            .removeDuplicates()
            .filter { $0 }
            .sink { [weak self] _ in
                self?.startKeyboardShortcuts()
            }
            .store(in: &cancellables)

        pipelineSuspensionHandlerID = interactionPipelineSuspensionController.addStateChangeHandler { [weak self] isSuspended, activeReasons in
            Task { @MainActor in
                self?.applyInteractionPipelineSuspension(isSuspended, activeReasons: activeReasons)
            }
        }

        windowCloseObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let window = notification.object as? NSWindow else {
                return
            }
            MainActor.assumeIsolated {
                self?.handleWindowWillClose(window)
            }
        }

        inlineCommandCoordinator.onStateChanged = { [weak self] active, capabilities in
            guard let self else {
                return
            }
            self.keyboardShortcuts.setInlineCommandState(active: active, capabilities: capabilities)
            if active {
                self.suggestionEngine.hideSuggestion()
                self.syncShortcutStateAfterAcceptance()
            }
        }

        Task { @MainActor [weak self] in
            self?.start()
            self?.openRequestedDebugWindowIfNeeded()
        }
    }

    func start() {
        installationLocationService.refresh()
        permissionService.startMonitoring()
        permissionService.refresh()
        refreshCompletionBackendSettings()
        if !hasStarted {
            acceptanceService.recoverPendingPasteboardInsertionIfNeeded()
            suggestionEngine.start()
            hasStarted = true
        }
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
                    guard let self else {
                        return
                    }
                    let handledByInlineCommand = await self.inlineCommandCoordinator.handleInputEvent(event)
                    if !handledByInlineCommand {
                        self.suggestionEngine.recordCapturedInputEvent(event)
                    }
                }
            },
            onEmojiCommand: { [weak self] command in
                Task { @MainActor in
                    await self?.handleInlineCommandKeyboardCommand(command)
                }
            },
            shortcutOwnershipDecision: { [weak self] command in
                guard let self else {
                    return .passThrough(reason: "controller-unavailable")
                }

                return self.suggestionEngine.shortcutOwnershipDecision(
                    for: command,
                    isSuggestionVisible: self.keyboardShortcuts.isSuggestionActive
                )
            }
        )
    }

    private func handleInlineCommandKeyboardCommand(_ command: EmojiKeyboardCommand) async {
        await inlineCommandCoordinator.handleKeyboardCommand(command)
        syncShortcutStateAfterAcceptance()
    }

    private func applyInteractionPipelineSuspension(
        _ suspended: Bool,
        activeReasons: Set<InteractionPipelineSuspensionReason>
    ) {
        let reason = activeReasons
            .map(\.rawValue)
            .sorted()
            .joined(separator: ",")
        let reasonSummary = reason.isEmpty ? "none" : reason

        suggestionEngine.setInteractionPipelineSuspended(suspended, reason: reasonSummary)
        keyboardShortcuts.setInteractionPipelineSuspended(suspended, reason: reasonSummary)
        inlineCommandCoordinator.setPipelineSuspended(suspended)

        guard !suspended else {
            return
        }

        permissionService.refresh()
        if hasStarted {
            startKeyboardShortcuts()
        }
    }

    private func handleShortcutCommand(_ command: KeyboardShortcutCommand) async {
        switch command {
        case .acceptNextWord:
            let outcome = await suggestionEngine.acceptNextWord(using: acceptanceService)
            syncShortcutStateAfterAcceptance()
            if outcome == .passedThrough {
                GeometryDebug.log("shortcut-command outcome=passed-through command=\(command.rawValue) replay=passthrough")
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

    func emojiVariantPreferences() -> EmojiVariantPreferences {
        emojiVariantPreferencesStore.load()
    }

    func saveEmojiVariantPreferences(_ preferences: EmojiVariantPreferences) {
        try? emojiVariantPreferencesStore.save(preferences)
        emojiPickerController.updatePreferences(preferences)
    }

    func macroPreferences() -> MacroPreferences {
        macroPreferencesStore.load()
    }

    func saveMacroPreferences(_ preferences: MacroPreferences) {
        try? macroPreferencesStore.save(preferences)
        macroCommandController.updatePreferences(preferences)
    }

    var emojiPickerAcceptKeyLabel: String {
        shortcutSettingsStore.load()[.acceptNextWord].displayName
    }

    func toggleAutocompleteEnabled() {
        setAutocompleteEnabled(!suggestionEngine.isAutocompleteEnabled)
    }

    func setAutocompleteEnabled(_ enabled: Bool) {
        suggestionEngine.setAutocompleteEnabled(enabled)
        syncShortcutStateAfterAcceptance()
    }

    func saveKeyboardShortcutSettings(_ settings: KeyboardShortcutSettings) {
        shortcutSettingsStore.save(settings)
        keyboardShortcuts.updateShortcutSettings(settings)
    }

    func stop() {
        inlineCommandCoordinator.cancelAll(reason: .cancelled)
        suggestionEngine.stop()
        keyboardShortcuts.stop()
        permissionService.stopMonitoring()
        hasStarted = false
    }

    func relaunch() {
        let configuration = Self.relaunchOpenConfiguration()
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            if let error {
                NSLog("AutoComp relaunch failed: \(error.localizedDescription)")
                return
            }
            Task { @MainActor in
                NSApp.terminate(nil)
            }
        }
    }

    static func relaunchOpenConfiguration() -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.allowsRunningApplicationSubstitution = false
        return configuration
    }

    func deletePersonalizationData() {
        try? personalizationStore.deleteAll()
        try? privacySettingsStore.resetWritingPreferences()
    }

    func deleteAllLocalPrivacyData() throws {
        try localPrivacyDataResetService.deleteAllLocalPrivacyData()
        suggestionEngine.resetInMemorySuggestionState(reason: "delete-all-local-privacy-data")
    }

    func savePrivacySettings(_ settings: PrivacySettings) {
        try? privacySettingsStore.save(settings)
        suggestionEngine.resetInMemorySuggestionState(reason: "privacy-settings-changed")
        productivityMetricsStore.reload()
    }

    func resetProductivityMetrics() {
        productivityMetricsStore.reset()
    }

    func saveDebugOptions(_ options: AutoCompDebugOptions) {
        debugOptionsStore.save(options)
        completionTraceStore.setEnabled(options.localDebugOptIn)
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

    func startPermissionGuidance(for kind: PermissionKind) {
        permissionGuidanceController.begin(for: kind)
    }

    func cancelPermissionGuidance() {
        permissionGuidanceController.cancel()
    }

    func deleteDebugArtifacts() throws {
        try debugArtifactStore.deleteAll()
        try completionTraceStore.deleteAll()
    }

    @discardableResult
    func withInteractionPipelineSuspended<T>(
        reason: InteractionPipelineSuspensionReason,
        operation: () throws -> T
    ) rethrows -> T {
        try interactionPipelineSuspensionController.withPipelineSuspended(
            reason: reason,
            operation: operation
        )
    }

    @discardableResult
    func withInteractionPipelineSuspended<T>(
        reason: InteractionPipelineSuspensionReason,
        operation: () async throws -> T
    ) async rethrows -> T {
        let token = interactionPipelineSuspensionController.suspend(reason: reason)
        defer { interactionPipelineSuspensionController.resume(token) }
        return try await operation()
    }

    func exportDebugLogs(to directory: URL) throws -> URL {
        try debugArtifactStore.exportDebugLogs(
            to: directory,
            options: debugOptions(),
            completionTraceStore: completionTraceStore
        )
    }

    func exportDebugLogsWithDirectoryPicker() -> DebugLogExportResult {
        withInteractionPipelineSuspended(reason: .settingsExport) {
            let panel = NSOpenPanel()
            panel.canChooseFiles = false
            panel.canChooseDirectories = true
            panel.canCreateDirectories = true
            panel.allowsMultipleSelection = false
            panel.prompt = "Export"
            panel.message = "Choose where to save the local debug log export."

            let response = withInteractionPipelineSuspended(reason: .openPanel) {
                panel.runModal()
            }
            guard response == .OK, let directory = panel.url else {
                return .cancelled
            }

            do {
                return .exported(try exportDebugLogs(to: directory))
            } catch {
                return .failed(error)
            }
        }
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
        completionBackendSummary = BackendSurface(settings: completionBackendSettings).summary
    }

    func saveCompletionBackendSettings(_ settings: CompletionBackendSettings) {
        let switchReason = completionProviderSwitchReason(from: completionBackendSettings, to: settings)
        completionBackendConfigurationService.save(settings)
        completionBackendSettings = settings
        completionBackendSummary = BackendSurface(settings: settings).summary
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
        return result
    }

    var isPlaygroundUITestMode: Bool {
        environment.usesPlaygroundTestProvider
    }

    var shouldRunSettingsConnectionUITest: Bool {
        environment.runsSettingsConnectionUITest
    }

    var settingsConnectionUITestBackendSettings: CompletionBackendSettings {
        environment.settingsConnectionUITestBackendSettings
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
        let window: NSWindow
        if let existingWindow = onboardingWindow, existingWindow.isVisible || existingWindow.isMiniaturized {
            if existingWindow.isMiniaturized {
                existingWindow.deminiaturize(nil)
            }
            window = existingWindow
        } else {
            window = makeWindow(
                title: "AutoComp Onboarding",
                size: Self.onboardingWindowContentSize,
                minSize: Self.onboardingWindowMinimumContentSize,
                maxSize: Self.onboardingWindowMaximumContentSize,
                content: OnboardingView()
                    .environmentObject(self)
                    .environmentObject(permissionService)
            )
        }
        onboardingWindow = window
        show(window, id: .onboarding)
    }

    func closeOnboardingWindow() {
        onboardingWindow?.close()
        onboardingWindow = nil
    }

    private func handleWindowWillClose(_ window: NSWindow?) {
        guard let window else {
            return
        }

        if window === onboardingWindow {
            activationPolicyController.windowDidClose(.onboarding)
            onboardingWindow = nil
            cancelPermissionGuidance()
            return
        }

        if window === settingsWindow {
            activationPolicyController.windowDidClose(.settings)
            settingsWindow = nil
            cancelPermissionGuidance()
            return
        }
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
                .environmentObject(installationLocationService)
        )
        window.delegate = settingsWindowResizeDelegate
        settingsWindow = window
        show(window, id: .settings)
    }

    private func makeWindow<Content: View>(
        title: String,
        size: NSSize,
        minSize: NSSize? = nil,
        maxSize: NSSize? = nil,
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
        if let maxSize {
            window.contentMaxSize = maxSize
            window.maxSize = window.frameRect(forContentRect: NSRect(origin: .zero, size: maxSize)).size
        }
        window.center()
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: content)
        return window
    }

    private func show(_ window: NSWindow, id: AppActivationPolicyController.WindowID) {
        activationPolicyController.windowDidOpen(id)
        window.makeKeyAndOrderFront(nil)
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
