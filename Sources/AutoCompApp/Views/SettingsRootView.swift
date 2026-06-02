import SwiftUI

struct SettingsRootView: View {
    @EnvironmentObject private var controller: AppController

    var body: some View {
        SettingsNavigationShell(selection: $controller.selectedSettingsSection)
    }
}
