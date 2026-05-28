import AutoCompCore
import Foundation

@MainActor
struct LocalPrivacyDataResetService {
    let personalizationStore: SecurePersonalizationStore
    let privacySettingsStore: PrivacySettingsStore
    let productivityMetricsStore: LocalProductivityMetricsStore
    let telemetryClient: any TelemetryClient
    let remoteCompletionConsentStore: RemoteCompletionConsentStore
    let debugOptionsStore: AutoCompDebugOptionsStore
    let debugArtifactStore: DebugArtifactStore
    let pasteboardRecoveryStore: PasteboardInsertionRecoveryStore?

    func deleteAllLocalPrivacyData() throws {
        try personalizationStore.deleteAll()
        try privacySettingsStore.resetLocalPrivacyDataState()
        productivityMetricsStore.reset()
        telemetryClient.deleteAll()
        remoteCompletionConsentStore.reset()
        debugOptionsStore.save(.normal)
        try debugArtifactStore.deleteAll()
        try pasteboardRecoveryStore?.delete()
    }
}
