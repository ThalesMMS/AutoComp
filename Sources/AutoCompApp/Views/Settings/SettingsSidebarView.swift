import SwiftUI

struct SettingsSidebarView: View {
    @Binding var selection: SettingsSection

    var body: some View {
        List(selection: $selection) {
            ForEach(SettingsSection.allCases) { section in
                SettingsSidebarRow(section: section)
                    .tag(section)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 220, idealWidth: 240, maxWidth: 280, maxHeight: .infinity)
        .navigationTitle("Preferences")
    }
}
