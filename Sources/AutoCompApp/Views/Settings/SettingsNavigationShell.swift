import AppKit
import SwiftUI

struct SettingsNavigationShell: View {
    private static let minimumSize = CGSize(width: 880, height: 560)

    @Binding var selection: SettingsSection
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SettingsSidebarView(selection: $selection)
                .navigationSplitViewColumnWidth(min: 220, ideal: 240, max: 280)
        } detail: {
            selectedSectionView
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .navigationSplitViewStyle(.balanced)
        .frame(minWidth: Self.minimumSize.width, minHeight: Self.minimumSize.height)
        .background(SettingsSidebarToolbarSuppressor())
        .onChange(of: columnVisibility) { _, newValue in
            if newValue != .all {
                columnVisibility = .all
            }
        }
    }

    @ViewBuilder
    private var selectedSectionView: some View {
        switch selection {
        case .general:
            GeneralSettingsView()
        case .setup:
            SetupSettingsView()
        case .model:
            ModelSettingsView()
        case .shortcuts:
            ShortcutSettingsView()
        case .privacy:
            PrivacySettingsView()
        case .apps:
            AppCompatibilitySettingsView()
        case .health:
            HealthDashboardView()
        case .statistics:
            StatisticsSettingsView()
        case .developer:
            DeveloperSettingsView()
        }
    }
}

private struct SettingsSidebarToolbarSuppressor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = SettingsSidebarToolbarSuppressorView()
        view.scheduleToolbarCleanup()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? SettingsSidebarToolbarSuppressorView)?.scheduleToolbarCleanup()
    }
}

private final class SettingsSidebarToolbarSuppressorView: NSView {
    private static let suppressedToolbarItemIdentifiers: Set<NSToolbarItem.Identifier> = [
        .toggleSidebar,
        .sidebarTrackingSeparator
    ]

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        scheduleToolbarCleanup()
    }

    func scheduleToolbarCleanup() {
        removeSuppressedToolbarItems()
        DispatchQueue.main.async { [weak self] in
            self?.removeSuppressedToolbarItems()
        }
    }

    private func removeSuppressedToolbarItems() {
        guard let toolbar = window?.toolbar else {
            return
        }

        for index in toolbar.items.indices.reversed() {
            let identifier = toolbar.items[index].itemIdentifier
            if Self.suppressedToolbarItemIdentifiers.contains(identifier) {
                toolbar.removeItem(at: index)
            }
        }
    }
}
