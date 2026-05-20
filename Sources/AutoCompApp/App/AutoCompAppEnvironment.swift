import AutoCompCore
import Foundation

@MainActor
struct AutoCompAppEnvironment {
    let permissionService: PermissionService
    let compatibilityCatalog: CompatibilityCatalog
    let compatibilitySettings: CompatibilitySettingsStore
    let privacySettingsStore: PrivacySettingsStore
    let personalizationStore: SecurePersonalizationStore
    let focusTrackingModel: FocusTrackingModel
    let visualContextCoordinator: VisualContextCoordinator
    let suggestionEngine: SuggestionEngine
    let acceptanceService: AcceptanceService
    let keyboardShortcuts: KeyboardShortcutService
    let completionBackendConfigurationService: CompletionBackendConfigurationService
    let usesInlinePreviewTestProvider: Bool
    let initialCompletionBackendSettings: CompletionBackendSettings

    init(arguments: [String] = ProcessInfo.processInfo.arguments) {
        let usesInlinePreviewTestProvider = arguments.contains("--ui-test-inline-preview")
        let completionBackendConfigurationService = CompletionBackendConfigurationService()
        let backendSettings = usesInlinePreviewTestProvider
            ? CompletionBackendSettings()
            : completionBackendConfigurationService.load()
        let permissionService = PermissionService()
        let compatibilityCatalog = CompatibilityCatalog()
        let compatibilitySettings = CompatibilitySettingsStore()
        let privacySettingsStore = PrivacySettingsStore()
        let inputSuppressionController = InputSuppressionController()
        let keyboardShortcuts = KeyboardShortcutService(inputSuppressionController: inputSuppressionController)
        let acceptanceService = AcceptanceService(inputSuppressionController: inputSuppressionController)
        let personalizationStore = SecurePersonalizationStore(directory: Self.personalizationDirectory())
        let focusTrackingModel = FocusTrackingModel()
        let visualContextCoordinator = VisualContextCoordinator(privacyStore: privacySettingsStore)
        let previewCoordinator = PreviewCoordinator()
        let presenter = ShortcutAwareSuggestionPresenter(
            previewCoordinator: previewCoordinator,
            setSuggestionActive: { active in
                keyboardShortcuts.setSuggestionActive(active)
            }
        )
        let completionProvider = Self.completionProvider(
            settings: backendSettings,
            usesInlinePreviewTestProvider: usesInlinePreviewTestProvider
        )
        let suggestionEngine = SuggestionEngine(
            contextProvider: focusTrackingModel,
            completionProvider: completionProvider,
            visualContextProvider: visualContextCoordinator,
            presenter: presenter,
            compatibilityCatalog: compatibilityCatalog,
            compatibilitySettings: compatibilitySettings,
            privacyStore: privacySettingsStore,
            shortcutLeakRepairInserter: acceptanceService
        )

        self.permissionService = permissionService
        self.compatibilityCatalog = compatibilityCatalog
        self.compatibilitySettings = compatibilitySettings
        self.privacySettingsStore = privacySettingsStore
        self.personalizationStore = personalizationStore
        self.focusTrackingModel = focusTrackingModel
        self.visualContextCoordinator = visualContextCoordinator
        self.suggestionEngine = suggestionEngine
        self.acceptanceService = acceptanceService
        self.keyboardShortcuts = keyboardShortcuts
        self.completionBackendConfigurationService = completionBackendConfigurationService
        self.usesInlinePreviewTestProvider = usesInlinePreviewTestProvider
        self.initialCompletionBackendSettings = backendSettings
        self.keyboardShortcuts.setSuggestionActive(false)
    }

    func completionProvider(for settings: CompletionBackendSettings) -> CompletionProvider {
        Self.completionProvider(
            settings: settings,
            usesInlinePreviewTestProvider: usesInlinePreviewTestProvider
        )
    }

    private static func completionProvider(
        settings: CompletionBackendSettings,
        usesInlinePreviewTestProvider: Bool
    ) -> CompletionProvider {
        let remoteProvider: CompletionProvider = usesInlinePreviewTestProvider
            ? InlinePreviewTestCompletionProvider()
            : RemoteCompletionProvider(configuration: settings.remoteConfiguration)
        let localProvider = LocalLlamaCompletionProvider(configuration: settings.localConfiguration)
        let appleFoundationProvider = AppleFoundationCompletionProvider()
        let fallbackKind = Self.fallbackKind(for: settings)

        return CompletionProviderRouter(
            activeKind: settings.engineKind,
            fallbackKind: fallbackKind,
            providers: [
                .remote: remoteProvider,
                .localLlama: localProvider,
                .appleIntelligence: appleFoundationProvider
            ]
        )
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

private actor InlinePreviewTestCompletionProvider: CompletionProvider {
    func complete(context: TextContext) async throws -> Suggestion {
        Suggestion(
            baseContextID: context.id,
            visibleText: " consegue me ajudar com isso.",
            latencyMs: 0
        )
    }
}
