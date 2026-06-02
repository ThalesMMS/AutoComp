import SwiftUI

struct SettingsPaneForm<Content: View>: View {
    let title: String
    @ViewBuilder let content: () -> Content

    var body: some View {
        Form {
            content()
        }
        .formStyle(.grouped)
        .padding()
        .navigationTitle(title)
    }
}
