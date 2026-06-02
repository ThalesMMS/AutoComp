import SwiftUI

struct SettingsSidebarRow: View {
    let section: SettingsSection

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: section.systemImage)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(section.accentColor)
                .frame(width: 22, alignment: .center)

            VStack(alignment: .leading, spacing: 2) {
                Text(section.title)
                    .font(.body)
                Text(section.sidebarDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)

            Circle()
                .fill(section.accentColor)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
        }
        .padding(.vertical, 4)
    }
}
