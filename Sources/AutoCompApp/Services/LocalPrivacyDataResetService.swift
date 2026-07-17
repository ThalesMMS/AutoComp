import AutoCompCore
import Foundation

@MainActor
struct LocalPrivacyDataResetService {
    let personalizationStore: SecurePersonalizationStore
    let privacySettingsStore: PrivacySettingsStore
    let productivityMetricsStore: LocalProductivityMetricsStore
    let remoteCompletionConsentStore: RemoteCompletionConsentStore
    let debugOptionsStore: AutoCompDebugOptionsStore
    let debugArtifactStore: DebugArtifactStore
    let completionTraceStore: CompletionTraceStore
    let pasteboardRecoveryStore: PasteboardInsertionRecoveryStore?

    func deleteAllLocalPrivacyData() throws {
        var firstError: Error?
        func attempt(_ operation: () throws -> Void) {
            do {
                try operation()
            } catch {
                if firstError == nil {
                    firstError = error
                }
            }
        }

        attempt { try personalizationStore.deleteAll() }
        attempt { try privacySettingsStore.resetLocalPrivacyDataState() }
        productivityMetricsStore.reset()
        remoteCompletionConsentStore.reset()
        debugOptionsStore.save(.normal)
        completionTraceStore.setEnabled(false)
        attempt { try debugArtifactStore.deleteAll() }
        attempt { try completionTraceStore.deleteAll() }
        attempt { try pasteboardRecoveryStore?.delete() }

        if let firstError {
            throw firstError
        }
    }
}
