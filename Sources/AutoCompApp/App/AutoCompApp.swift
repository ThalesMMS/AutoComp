import SwiftUI

@main
struct AutoCompApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = AppController()
    @StateObject private var updateService = SparkleUpdaterService()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra("AutoComp", systemImage: "text.cursor") {
            MenuBarContentView(
                canCheckForUpdates: updateService.canCheckForUpdates,
                checkForUpdates: {
                    updateService.checkForUpdates()
                }
            )
                .environmentObject(controller)
                .environmentObject(controller.permissionService)
                .environmentObject(controller.suggestionEngine)
                .environmentObject(controller.installationLocationService)
        }
        .menuBarExtraStyle(.window)

        Window("AutoComp Onboarding", id: "onboarding") {
            OnboardingView()
                .environmentObject(controller)
                .environmentObject(controller.permissionService)
                .frame(minWidth: 520, minHeight: 440)
        }
        .defaultSize(width: 560, height: 560)

        Settings {
            SettingsRootView()
                .environmentObject(controller)
                .environmentObject(controller.permissionService)
                .environmentObject(controller.suggestionEngine)
                .environmentObject(controller.localLlamaRuntimeStatusStore)
                .frame(minWidth: 720, minHeight: 520)
        }
    }
}
