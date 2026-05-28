import AutoCompCore
import Foundation

#if AUTOCOMP_LLAMA_RUNTIME
import AutoCompLlamaRuntime
#endif

@MainActor
struct AutoCompAppEnvironment {
    let permissionService: PermissionService
    let compatibilityCatalog: CompatibilityCatalog
    let compatibilitySettings: CompatibilitySettingsStore
    let privacySettingsStore: PrivacySettingsStore
    let personalizationStore: SecurePersonalizationStore
    let focusTrackingModel: FocusTrackingModel
    let visualContextCoordinator: VisualContextCoordinator
    let clipboardContextProvider: SystemClipboardContextProvider
    let suggestionEngine: SuggestionEngine
    let acceptanceService: AcceptanceService
    let keyboardShortcuts: KeyboardShortcutService
    let inputSourceMonitor: InputSourceMonitor
    let shortcutSettingsStore: KeyboardShortcutSettingsStore
    let completionBackendConfigurationService: CompletionBackendConfigurationService
    let localLlamaRuntimeStatusStore: LocalLlamaRuntimeStatusStore
    let remoteCompletionConsentStore: RemoteCompletionConsentStore
    let debugOptionsStore: AutoCompDebugOptionsStore
    let debugArtifactStore: DebugArtifactStore
    let pasteboardRecoveryStore: PasteboardInsertionRecoveryStore
    let suggestionDebugLogger: SuggestionDebugLogger
    let overlayRecoveryAdvisor: OverlayRecoveryAdvisor
    let productivityMetricsStore: LocalProductivityMetricsStore
    let installationLocationService: InstallationLocationService
    let telemetryClient: any TelemetryClient
    let usesInlinePreviewTestProvider: Bool
    let usesPlaygroundTestProvider: Bool
    let initialCompletionBackendSettings: CompletionBackendSettings

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let usesInlinePreviewTestProvider = arguments.contains("--ui-test-inline-preview")
        let usesPlaygroundTestProvider = arguments.contains("--ui-test-playground")
        let completionBackendConfigurationService = CompletionBackendConfigurationService()
        let localLlamaRuntimeStatusStore = LocalLlamaRuntimeStatusStore()
        let remoteCompletionConsentStore = RemoteCompletionConsentStore()
        let backendSettings = usesInlinePreviewTestProvider
            ? CompletionBackendSettings()
            : completionBackendConfigurationService.load()
        let permissionService = PermissionService()
        let compatibilityCatalog = CompatibilityCatalog()
        let compatibilitySettings = CompatibilitySettingsStore()
        let privacySettingsStore = PrivacySettingsStore()
        let debugOptionsStore = AutoCompDebugOptionsStore()
        let debugArtifactStore = DebugArtifactStore()
        let pasteboardRecoveryStore = PasteboardInsertionRecoveryStore()
        let suggestionDebugLogger = SuggestionDebugLogger(artifactStore: debugArtifactStore)
        let overlayRecoveryAdvisor = OverlayRecoveryAdvisor()
        let productivityMetricsStore = LocalProductivityMetricsStore(
            privacyStore: privacySettingsStore
        )
        let installationLocationService = InstallationLocationService()
        let telemetryClient = DisabledTelemetryClient()
        let inputSuppressionController = InputSuppressionController()
        let inputSourceMonitor = InputSourceMonitor()
        let shortcutSettingsStore = KeyboardShortcutSettingsStore()
        let keyboardShortcuts = KeyboardShortcutService(
            inputSuppressionController: inputSuppressionController,
            shortcutSettings: shortcutSettingsStore.load(),
            inputMethodStateProvider: { inputSourceMonitor.currentState }
        )
        let acceptanceService = AcceptanceService(
            inputSuppressionController: inputSuppressionController,
            pasteboardRecoveryStore: pasteboardRecoveryStore
        )
        let personalizationStore = SecurePersonalizationStore(directory: Self.personalizationDirectory())
        let focusTrackingModel = FocusTrackingModel(
            axCapabilitySnapshotRecorder: AXCapabilitySnapshotRecorder(
                artifactStore: debugArtifactStore
            )
        )
        let visualContextCoordinator = VisualContextCoordinator(privacyStore: privacySettingsStore)
        let clipboardContextProvider = SystemClipboardContextProvider()
        let keystrokeBufferFallback = KeystrokeBufferFallback()
        let previewCoordinator = PreviewCoordinator(
            overlayRecoveryAdvisor: overlayRecoveryAdvisor,
            focusDebugOverlayPresenter: FocusDebugOverlayController(
                visualContextSessionProvider: {
                    visualContextCoordinator.currentSession()
                }
            )
        )
        let presenter = ShortcutAwareSuggestionPresenter(
            previewCoordinator: previewCoordinator,
            setSuggestionActive: { active in
                keyboardShortcuts.setSuggestionActive(active)
            }
        )
        let completionProvider = Self.completionProvider(
            settings: backendSettings,
            usesInlinePreviewTestProvider: usesInlinePreviewTestProvider,
            remoteConsentStore: remoteCompletionConsentStore,
            localLlamaRuntimeStatusStore: localLlamaRuntimeStatusStore
        )
        let suggestionEngine = SuggestionEngine(
            contextProvider: focusTrackingModel,
            completionProvider: completionProvider,
            visualContextProvider: visualContextCoordinator,
            clipboardContextProvider: clipboardContextProvider,
            presenter: presenter,
            compatibilityCatalog: compatibilityCatalog,
            compatibilitySettings: compatibilitySettings,
            privacyStore: privacySettingsStore,
            productivityMetrics: productivityMetricsStore,
            multiSuggestionEnabled: backendSettings.multiSuggestionEnabled,
            inputMethodStateProvider: { inputSourceMonitor.currentState },
            keystrokeBufferFallback: keystrokeBufferFallback,
            shortcutLeakRepairInserter: acceptanceService,
            suggestionDebugLogger: suggestionDebugLogger,
            debugOptionsProvider: {
                debugOptionsStore.load()
            }
        )

        self.permissionService = permissionService
        self.compatibilityCatalog = compatibilityCatalog
        self.compatibilitySettings = compatibilitySettings
        self.privacySettingsStore = privacySettingsStore
        self.personalizationStore = personalizationStore
        self.focusTrackingModel = focusTrackingModel
        self.visualContextCoordinator = visualContextCoordinator
        self.clipboardContextProvider = clipboardContextProvider
        self.suggestionEngine = suggestionEngine
        self.acceptanceService = acceptanceService
        self.keyboardShortcuts = keyboardShortcuts
        self.inputSourceMonitor = inputSourceMonitor
        self.shortcutSettingsStore = shortcutSettingsStore
        self.completionBackendConfigurationService = completionBackendConfigurationService
        self.localLlamaRuntimeStatusStore = localLlamaRuntimeStatusStore
        self.remoteCompletionConsentStore = remoteCompletionConsentStore
        self.debugOptionsStore = debugOptionsStore
        self.debugArtifactStore = debugArtifactStore
        self.pasteboardRecoveryStore = pasteboardRecoveryStore
        self.suggestionDebugLogger = suggestionDebugLogger
        self.overlayRecoveryAdvisor = overlayRecoveryAdvisor
        self.productivityMetricsStore = productivityMetricsStore
        self.installationLocationService = installationLocationService
        self.telemetryClient = telemetryClient
        self.usesInlinePreviewTestProvider = usesInlinePreviewTestProvider
        self.usesPlaygroundTestProvider = usesPlaygroundTestProvider
        self.initialCompletionBackendSettings = backendSettings
        self.keyboardShortcuts.setSuggestionActive(false)
    }

    func completionProvider(for settings: CompletionBackendSettings) -> CompletionProvider {
        Self.completionProvider(
            settings: settings,
            usesInlinePreviewTestProvider: usesInlinePreviewTestProvider,
            remoteConsentStore: remoteCompletionConsentStore,
            localLlamaRuntimeStatusStore: localLlamaRuntimeStatusStore
        )
    }

    func playgroundCompletionProvider(for settings: CompletionBackendSettings) -> CompletionProvider {
        if usesPlaygroundTestProvider {
            return PlaygroundTestCompletionProvider()
        }
        return completionProvider(for: settings)
    }

    private static func completionProvider(
        settings: CompletionBackendSettings,
        usesInlinePreviewTestProvider: Bool,
        remoteConsentStore: RemoteCompletionConsentStore,
        localLlamaRuntimeStatusStore: LocalLlamaRuntimeStatusStore
    ) -> CompletionProvider {
        let remoteProvider: CompletionProvider = usesInlinePreviewTestProvider
            ? InlinePreviewTestCompletionProvider()
            : RemoteCompletionProvider(configuration: settings.remoteConfiguration)
        let localProvider = Self.localLlamaProvider(
            settings: settings,
            runtimeStatusStore: localLlamaRuntimeStatusStore
        )
        let appleFoundationProvider = AppleFoundationCompletionProvider(stopSequences: settings.stopSequences)
        let fallbackKind = Self.fallbackKind(for: settings)

        return CompletionProviderRouter(
            activeKind: settings.engineKind,
            fallbackKind: fallbackKind,
            providers: [
                .remote: remoteProvider,
                .localLlama: localProvider,
                .appleIntelligence: appleFoundationProvider
            ],
            remoteConsentChecker: usesInlinePreviewTestProvider
                ? AllowingRemoteCompletionConsentChecker()
                : RemoteCompletionConsentPolicy(
                    store: remoteConsentStore,
                    remoteBaseURL: settings.remoteBaseURL
                )
        )
    }

    private static func localLlamaProvider(
        settings: CompletionBackendSettings,
        runtimeStatusStore: LocalLlamaRuntimeStatusStore
    ) -> CompletionProvider {
        #if AUTOCOMP_LLAMA_RUNTIME
        return LocalLlamaCompletionProvider(
            configuration: settings.localConfiguration,
            runtime: LocalLlamaRuntimeCore(backend: LlamaCppRuntimeBackend()),
            runtimeStatusRecorder: runtimeStatusStore.makeRecorder()
        )
        #else
        return LocalLlamaCompletionProvider(
            configuration: settings.localConfiguration,
            runtimeStatusRecorder: runtimeStatusStore.makeRecorder()
        )
        #endif
    }

    private static func fallbackKind(for settings: CompletionBackendSettings) -> CompletionEngineKind? {
        switch settings.engineKind {
        case .localLlama where settings.fallbackToRemoteOnLocalFailure:
            return .remote
        case .appleIntelligence where settings.fallbackToRemoteOnAppleIntelligenceFailure:
            return .remote
        default:
            return nil
        }
    }

    private static func personalizationDirectory() -> URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AutoComp", isDirectory: true)
            .appendingPathComponent("Personalization", isDirectory: true)
    }
}

private actor InlinePreviewTestCompletionProvider: ClipboardContextAwareCompletionProvider {
    private let requestFactory = CompletionRequestFactory()

    func complete(context: TextContext) async throws -> Suggestion {
        try await complete(context: context, privacySettings: PrivacySettings(), visualContext: nil)
    }

    func complete(
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?
    ) async throws -> Suggestion {
        try await complete(
            context: context,
            privacySettings: privacySettings,
            visualContext: visualContext,
            clipboardContext: nil
        )
    }

    func complete(
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?,
        clipboardContext: ClipboardContextSnapshot?
    ) async throws -> Suggestion {
        let request = requestFactory.makeRequest(
            for: context,
            configuration: RemoteCompletionConfiguration(
                baseURL: "ui-test://inline-preview",
                apiKey: "local",
                model: "inline-preview-test"
            ),
            privacySettings: privacySettings,
            visualContext: visualContext,
            clipboardContext: clipboardContext
        )
        let rawText = request.mode == .fillInMiddle
            ? "adiada para sexta-feira\(context.textAfterCursor ?? "")"
            : " consegue me ajudar com isso."
        let normalizedText = SuggestionTextNormalizer.normalize(
            rawText: rawText,
            request: request
        )
        return Suggestion(
            baseContextID: context.id,
            visibleText: normalizedText,
            rawText: rawText,
            latencyMs: 0
        )
    }
}

private actor PlaygroundTestCompletionProvider: CompletionProvider {
    func complete(context: TextContext) async throws -> Suggestion {
        let rawText = "Completion:\n playground completion\(context.textAfterCursor ?? "")"
        let normalizedText = SuggestionTextNormalizer.normalize(
            rawText: rawText,
            precedingText: context.textBeforeCursor,
            trailingText: context.textAfterCursor
        )
        return Suggestion(
            baseContextID: context.id,
            visibleText: normalizedText,
            rawText: rawText,
            latencyMs: 5
        )
    }
}
