import AutoCompCore
import SwiftUI

struct SetupSettingsView: View {
    @EnvironmentObject private var controller: AppController
    @EnvironmentObject private var permissions: PermissionService
    @EnvironmentObject private var installationLocation: InstallationLocationService

    var body: some View {
        SettingsPaneForm(title: "Setup") {
            if installationLocation.status.shouldWarn {
                Section("Install location") {
                    SettingsActionRow(
                        title: "Move to Applications",
                        subtitle: "Move AutoComp to \(installationLocation.status.recommendedDirectoryPath) before granting macOS permissions.",
                        state: .warning,
                        statusTitle: "Recommended"
                    )

                    LabeledContent("Current folder", value: installationLocation.status.currentDirectoryPath)

                    HStack {
                        Button("Open Applications") {
                            installationLocation.openApplicationsFolder()
                        }
                        Button("Reveal App") {
                            installationLocation.revealCurrentApp()
                        }
                    }
                }
            }

            Section("Guided setup") {
                Button("Open Onboarding") {
                    controller.showOnboardingWindow()
                }
                SectionFooterNote(text: "Use onboarding to re-check permissions and first-run readiness.")
            }

            Section("Required access") {
                ForEach(permissions.permissionPresentations.filter { $0.requirement == .required }) { permission in
                    permissionCard(permission)
                }
            }

            Section("Optional access") {
                ForEach(permissions.permissionPresentations.filter { $0.requirement == .optional }) { permission in
                    permissionCard(permission)
                }
            }

            Section("Backend") {
                let backendSettings = controller.completionBackendSettings
                let backendSurface = BackendSurface(settings: backendSettings)
                SettingsActionRow(
                    title: "Completion backend",
                    subtitle: "Active: \(backendSettings.engineKind.displayName). Requests use the model selected in Model."
                )
                DisclosureGroup("Backend details") {
                    LabeledContent("Selected engine", value: backendSettings.engineKind.displayName)
                    LabeledContent("Request destination", value: backendSurface.requestDestinationTitle)
                    SectionFooterNote(text: backendSurface.summary)
                }
                Button("Open Model Settings") {
                    controller.selectedSettingsSection = .model
                }
            }

            Section("Runtime identity") {
                LabeledContent("Bundle ID", value: permissions.runtimeBundleID)
                DisclosureGroup("Executable path") {
                    SectionFooterNote(text: permissions.runtimeExecutablePath)
                        .textSelection(.enabled)
                }
            }
        }
    }

    @ViewBuilder
    private func permissionCard(_ permission: PermissionPresentation) -> some View {
        PermissionCard(permission: permission) {
            if permission.needsRelaunch {
                Button("Relaunch AutoComp") {
                    controller.relaunch()
                }
            }
            Button("Open System Settings") {
                controller.startPermissionGuidance(for: permission.kind)
            }
            if !permission.needsRelaunch {
                Button(permission.requestButtonTitle) {
                    controller.startPermissionGuidance(for: permission.kind)
                }
            }
        }
    }
}

struct OverlayRecoveryRecommendationView: View {
    @ObservedObject var advisor: OverlayRecoveryAdvisor
    @State private var isConfirmingFailureCountReset = false

    var body: some View {
        SettingsActionRow(
            title: "Safe simple mode",
            state: advisor.shouldRecommendSafeOverlayMode ? .warning : .ok,
            statusTitle: advisor.safeModeStatusTitle
        )
        LabeledContent("Advanced overlay failures", value: "\(advisor.advancedOverlayFailureCount)")

        if advisor.shouldRecommendSafeOverlayMode {
            StatusBadge("Recommended", state: .warning)
        }

        DisclosureGroup("Details") {
            SectionFooterNote(text: advisor.recommendationMessage)
        }

        Button("Clear Overlay Failure Count", role: .destructive) {
            isConfirmingFailureCountReset = true
        }
        .disabled(advisor.advancedOverlayFailureCount == 0)
        .confirmationDialog(
            "Clear Overlay Failure Count?",
            isPresented: $isConfirmingFailureCountReset,
            titleVisibility: .visible
        ) {
            Button("Clear Failure Count", role: .destructive) {
                advisor.resetAdvancedOverlayFailures()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This clears the saved advanced overlay fallback count used for safe mode recommendations.")
        }
    }
}
