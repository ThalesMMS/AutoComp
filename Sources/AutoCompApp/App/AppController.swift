import AppKit
import Combine
import AutoCompCore
import Foundation
import SwiftUI

@MainActor
final class AppController: ObservableObject {
    @Published var selectedSettingsSection: SettingsSection = .permissions
    @Published private(set) var completionBackendSummary: String
    @Published var completionBackendSettings: CompletionBackendSettings

    let permissionService: PermissionService
    let compatibilityCatalog: CompatibilityCatalog
    let compatibilitySettings: CompatibilitySettingsStore
    let privacySettingsStore: PrivacySettingsStore
    let personalizationStore: SecurePersonalizationStore
    let suggestionEngine: SuggestionEngine

    private let acceptanceService: AcceptanceService
    private let keyboardShortcuts: KeyboardShortcutService
    private let completionBackendConfigurationService: CompletionBackendConfigurationService
    private let usesInlinePreviewTestProvider: Bool
    private var onboardingWindow: NSWindow?
    private var settingsWindow: NSWindow?
    private var cancellables: Set<AnyCancellable> = []

    init() {
        let arguments = ProcessInfo.processInfo.arguments
        let usesInlinePreviewTestProvider = arguments.contains("--ui-test-inline-preview")
        let completionBackendConfigurationService = CompletionBackendConfigurationService()
        let backendSettings = usesInlinePreviewTestProvider
            ? CompletionBackendSettings()
            : completionBackendConfigurationService.load()
        let permissionService = PermissionService()
        let compatibilityCatalog = CompatibilityCatalog()
        let compatibilitySettings = CompatibilitySettingsStore()
        let privacySettingsStore = PrivacySettingsStore()
        let keyboardShortcuts = KeyboardShortcutService()
        let acceptanceService = AcceptanceService()
        let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AutoComp", isDirectory: true)
        let personalizationStore = SecurePersonalizationStore(directory: supportDirectory.appendingPathComponent("Personalization", isDirectory: true))
        let previewCoordinator = PreviewCoordinator()
        let presenter = ShortcutAwareSuggestionPresenter(
            previewCoordinator: previewCoordinator,
            setSuggestionActive: { active in
                keyboardShortcuts.setSuggestionActive(active)
            }
        )
        let completionProvider: CompletionProvider = usesInlinePreviewTestProvider
            ? InlinePreviewTestCompletionProvider()
            : RemoteCompletionProvider(configuration: backendSettings.remoteConfiguration)
        let suggestionEngine = SuggestionEngine(
            contextProvider: AXTextContextService(),
            completionProvider: completionProvider,
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
        self.suggestionEngine = suggestionEngine
        self.acceptanceService = acceptanceService
        self.keyboardShortcuts = keyboardShortcuts
        self.completionBackendConfigurationService = completionBackendConfigurationService
        self.usesInlinePreviewTestProvider = usesInlinePreviewTestProvider
        self.completionBackendSettings = backendSettings
        self.completionBackendSummary = backendSettings.summary
        self.keyboardShortcuts.setSuggestionActive(false)

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
        permissionService.refresh()
        refreshCompletionBackendSettings()
        suggestionEngine.start()
        startKeyboardShortcuts()
    }

    private func startKeyboardShortcuts() {
        keyboardShortcuts.start(
            onTab: { [weak self] in
                guard let self else { return }
                Task {
                    await self.suggestionEngine.acceptNextWord(using: self.acceptanceService)
                    self.syncShortcutStateAfterAcceptance()
                }
            },
            onAcceptAll: { [weak self] in
                guard let self else { return }
                Task {
                    await self.suggestionEngine.acceptAll(using: self.acceptanceService)
                    self.syncShortcutStateAfterAcceptance()
                }
            },
            onSuggestionTriggerKey: { [weak self] in
                Task { @MainActor in
                    self?.suggestionEngine.recordSuggestionTriggerKey()
                }
            }
        )
    }

    private func syncShortcutStateAfterAcceptance() {
        let hasSuggestion = suggestionEngine.currentSuggestion != nil
        keyboardShortcuts.setSuggestionActive(hasSuggestion)
        if !hasSuggestion {
            keyboardShortcuts.clearShortcutGrace()
        }
    }

    func stop() {
        suggestionEngine.stop()
        keyboardShortcuts.stop()
    }

    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            guard error == nil else { return }
            NSApp.terminate(nil)
        }
    }

    func deletePersonalizationData() {
        try? personalizationStore.deleteAll()
    }

    func refreshCompletionBackendSettings() {
        guard !usesInlinePreviewTestProvider else {
            return
        }
        completionBackendSettings = completionBackendConfigurationService.load()
        completionBackendSummary = completionBackendSettings.summary
    }

    func saveCompletionBackendSettings(_ settings: CompletionBackendSettings) {
        completionBackendConfigurationService.save(settings)
        completionBackendSettings = settings
        completionBackendSummary = settings.summary
        suggestionEngine.updateCompletionProvider(
            RemoteCompletionProvider(configuration: settings.remoteConfiguration),
            status: "Completion backend updated"
        )
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
        let window = settingsWindow ?? makeWindow(
            title: "AutoComp Settings",
            size: NSSize(width: 760, height: 560),
            content: SettingsRootView()
                .environmentObject(self)
                .environmentObject(permissionService)
                .environmentObject(suggestionEngine)
        )
        settingsWindow = window
        show(window)
    }

    private func makeWindow<Content: View>(title: String, size: NSSize, content: Content) -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = title
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
        } else if arguments.contains("--ui-test-onboarding") {
            showOnboardingWindow()
        }
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
