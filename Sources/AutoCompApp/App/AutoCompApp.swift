import SwiftUI

@main
struct AutoCompApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var controller = AppController()
    @Environment(\.openWindow) private var openWindow

    var body: some Scene {
        MenuBarExtra("AutoComp", systemImage: "text.cursor") {
            MenuBarContentView()
                .environmentObject(controller)
                .environmentObject(controller.permissionService)
                .environmentObject(controller.suggestionEngine)
        }
        .menuBarExtraStyle(.window)

        Window("AutoComp Onboarding", id: "onboarding") {
            OnboardingView()
                .environmentObject(controller)
                .environmentObject(controller.permissionService)
                .frame(minWidth: 520, minHeight: 440)
        }

        Settings {
            SettingsRootView()
                .environmentObject(controller)
                .environmentObject(controller.permissionService)
                .environmentObject(controller.suggestionEngine)
                .frame(minWidth: 720, minHeight: 520)
        }
    }
}
