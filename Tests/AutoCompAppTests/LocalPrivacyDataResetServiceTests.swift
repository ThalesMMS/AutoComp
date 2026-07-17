import AutoCompCore
@testable import AutoCompApp
import Security
import XCTest

@MainActor
final class LocalPrivacyDataResetServiceTests: XCTestCase {
    func testDeleteContinuesAfterFailureAndThrowsOnlyAfterRemainingStoresAreReset() throws {
        let defaultsName = "LocalPrivacyDataResetServiceTests.failure.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defaults.removePersistentDomain(forName: defaultsName)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("autocomp-privacy-reset-failure-\(UUID().uuidString)", isDirectory: true)
        let debugDirectory = root.appendingPathComponent("DebugArtifacts", isDirectory: true)
        let traceDirectory = root.appendingPathComponent("CompletionTraces", isDirectory: true)
        let pasteboardDirectory = root.appendingPathComponent("PasteboardRecovery", isDirectory: true)
        let keychainService = "com.autocomp.tests.personalization.failure.\(UUID().uuidString)"
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: root)
            deleteKeychainItem(service: keychainService, account: "local-profile-key")
        }

        try FileManager.default.createDirectory(at: debugDirectory, withIntermediateDirectories: true)
        try Data("debug".utf8).write(to: debugDirectory.appendingPathComponent("artifact.txt"))
        let privacySettingsStore = PrivacySettingsStore(defaults: defaults, key: "privacy")
        let metricsStore = LocalProductivityMetricsStore(
            defaults: defaults,
            key: "metrics",
            privacyStore: privacySettingsStore,
            calendar: utcCalendar()
        )
        let traceStore = CompletionTraceStore(directory: traceDirectory, isEnabled: true)
        traceStore.record(CompletionTraceEvent(
            context: CompletionTraceContext(),
            event: .published,
            outcome: .published
        ))
        traceStore.flush()
        let pasteboardStore = PasteboardInsertionRecoveryStore(directory: pasteboardDirectory)
        try pasteboardStore.save(PasteboardInsertionRecoverySnapshot(
            id: "continued-reset",
            createdAt: Date(),
            previousItems: nil
        ))

        let service = LocalPrivacyDataResetService(
            personalizationStore: SecurePersonalizationStore(
                directory: root.appendingPathComponent("Personalization", isDirectory: true),
                service: keychainService,
                account: "local-profile-key"
            ),
            privacySettingsStore: privacySettingsStore,
            productivityMetricsStore: metricsStore,
            remoteCompletionConsentStore: RemoteCompletionConsentStore(defaults: defaults, key: "consent"),
            debugOptionsStore: AutoCompDebugOptionsStore(defaults: defaults, key: "debug"),
            debugArtifactStore: DebugArtifactStore(
                directory: debugDirectory,
                fileManager: FailingRemoveFileManager()
            ),
            completionTraceStore: traceStore,
            pasteboardRecoveryStore: pasteboardStore
        )

        XCTAssertThrowsError(try service.deleteAllLocalPrivacyData())
        XCTAssertTrue(FileManager.default.fileExists(atPath: debugDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: traceDirectory.path))
        XCTAssertFalse(pasteboardStore.hasPendingSnapshot())
    }

    func testDeleteAllLocalPrivacyDataRemovesSensitiveStateAndPreservesOperationalConfiguration() throws {
        let defaultsName = "LocalPrivacyDataResetServiceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defaults.removePersistentDomain(forName: defaultsName)
        let supportDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("autocomp-privacy-reset-\(UUID().uuidString)", isDirectory: true)
        let operationalDirectory = supportDirectory.appendingPathComponent("Operational", isDirectory: true)
        let operationalFile = operationalDirectory.appendingPathComponent("cache.txt")
        let personalizationDirectory = supportDirectory.appendingPathComponent("Personalization", isDirectory: true)
        let debugDirectory = supportDirectory.appendingPathComponent("DebugArtifacts", isDirectory: true)
        let pasteboardRecoveryDirectory = supportDirectory.appendingPathComponent("PasteboardRecovery", isDirectory: true)
        let personalizationKeychainService = "com.autocomp.tests.personalization.\(UUID().uuidString)"
        let backendKeychainService = "com.autocomp.tests.backend.\(UUID().uuidString)"
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
            try? FileManager.default.removeItem(at: supportDirectory)
            deleteKeychainItem(service: personalizationKeychainService, account: "local-profile-key")
            deleteKeychainItem(service: backendKeychainService, account: "remote-api-key")
        }

        let privacySettingsStore = PrivacySettingsStore(defaults: defaults, key: "privacy")
        try privacySettingsStore.save(PrivacySettings(
            collectionEnabled: true,
            clipboardContextEnabled: true,
            screenContextEnabled: true,
            productivityMetricsEnabled: true,
            localPersonalizationEnabled: true,
            writingPreferences: WritingPreferences(
                enabled: true,
                rules: ["Write objectively", "Avoid emoji"]
            ),
            perAppRules: ["com.apple.TextEdit": false],
            perDomainRules: ["docs.google.com": false]
        ))

        try FileManager.default.createDirectory(at: operationalDirectory, withIntermediateDirectories: true)
        try "non-sensitive operational state".write(to: operationalFile, atomically: true, encoding: .utf8)

        let personalizationStore = SecurePersonalizationStore(
            directory: personalizationDirectory,
            service: personalizationKeychainService,
            account: "local-profile-key"
        )
        try personalizationStore.append(
            "SECRET personalization text",
            appBundleID: "com.apple.TextEdit",
            domain: "docs.google.com"
        )

        let productivityMetricsStore = LocalProductivityMetricsStore(
            defaults: defaults,
            key: "metrics",
            privacyStore: privacySettingsStore,
            calendar: utcCalendar(),
            now: { Date(timeIntervalSince1970: 100) }
        )
        productivityMetricsStore.recordAcceptedText("secret accepted words")
        productivityMetricsStore.recordDismissedSuggestion()
        productivityMetricsStore.recordCompletionLatency(CompletionLatencyReport(backendMs: 41, totalMs: 90))

        let remoteConsentStore = RemoteCompletionConsentStore(defaults: defaults, key: "remoteConsent")

        let debugOptionsStore = AutoCompDebugOptionsStore(defaults: defaults, key: "debug")
        debugOptionsStore.save(AutoCompDebugOptions(localDebugOptIn: true))
        let debugArtifactStore = DebugArtifactStore(directory: debugDirectory)
        let completionTraceDirectory = supportDirectory.appendingPathComponent("CompletionTraces", isDirectory: true)
        let completionTraceStore = CompletionTraceStore(
            directory: completionTraceDirectory,
            isEnabled: true
        )
        completionTraceStore.record(CompletionTraceEvent(
            context: CompletionTraceContext(),
            event: .published,
            outcome: .published
        ))
        completionTraceStore.flush()
        try debugArtifactStore.saveSensitiveArtifact(
            named: "seed",
            contents: "SECRET debug artifact",
            options: AutoCompDebugOptions(localDebugOptIn: true)
        )
        let pasteboardRecoveryStore = PasteboardInsertionRecoveryStore(directory: pasteboardRecoveryDirectory)
        try pasteboardRecoveryStore.save(PasteboardInsertionRecoverySnapshot(
            id: "privacy-reset-pasteboard",
            createdAt: Date(),
            previousItems: [
                PreservedPasteboardItem(dataByType: [.string: Data("SECRET pasteboard material".utf8)])
            ]
        ))

        let backendSettingsStore = CompletionBackendConfigurationService(
            defaults: defaults,
            keychainService: backendKeychainService,
            keychainAccount: "remote-api-key"
        )
        let backendSettings = CompletionBackendSettings(
            engineKind: .remote,
            remoteBaseURL: "http://127.0.0.1:8000",
            remoteAPIKey: "backend-api-key-material",
            remoteModel: "test-model",
            localModelPath: "/tmp/autocomp-local.gguf",
            localMaxRAMBytes: 2_048,
            fallbackToRemoteOnLocalFailure: true,
            fallbackToRemoteOnAppleIntelligenceFailure: true,
            multiSuggestionEnabled: false
        )
        backendSettingsStore.save(backendSettings)
        remoteConsentStore.grantConsent(
            for: .remoteBackend,
            remoteBaseURL: backendSettings.remoteBaseURL
        )

        let compatibilitySettingsStore = CompatibilitySettingsStore(defaults: defaults)
        compatibilitySettingsStore.setMode(.manualOnly, for: "com.apple.TextEdit")
        compatibilitySettingsStore.setMode(.disabled, forDomain: "https://docs.google.com/document/d/example")

        XCTAssertEqual(personalizationStore.recordCount(), 1)
        XCTAssertGreaterThan(productivityMetricsStore.snapshot.wordsAcceptedTotal, 0)
        XCTAssertTrue(remoteConsentStore.hasConsent(for: .remoteBackend, remoteBaseURL: backendSettings.remoteBaseURL))
        XCTAssertEqual(debugArtifactStore.artifactCount(), 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: completionTraceDirectory.path))
        XCTAssertTrue(pasteboardRecoveryStore.hasPendingSnapshot())
        XCTAssertTrue(debugOptionsStore.load().allowsSensitiveDebug)
        XCTAssertEqual(backendSettingsStore.load(localRuntimeState: .unavailableInBuild).remoteAPIKey, "backend-api-key-material")
        XCTAssertTrue(FileManager.default.fileExists(atPath: operationalFile.path))

        let resetService = LocalPrivacyDataResetService(
            personalizationStore: personalizationStore,
            privacySettingsStore: privacySettingsStore,
            productivityMetricsStore: productivityMetricsStore,
            remoteCompletionConsentStore: remoteConsentStore,
            debugOptionsStore: debugOptionsStore,
            debugArtifactStore: debugArtifactStore,
            completionTraceStore: completionTraceStore,
            pasteboardRecoveryStore: pasteboardRecoveryStore
        )

        try resetService.deleteAllLocalPrivacyData()

        let privacySettings = privacySettingsStore.load()
        XCTAssertEqual(personalizationStore.recordCount(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: personalizationDirectory.path))
        XCTAssertFalse(privacySettings.writingPreferences.enabled)
        XCTAssertTrue(privacySettings.writingPreferences.rules.isEmpty)
        XCTAssertEqual(productivityMetricsStore.snapshot.wordsAcceptedTotal, 0)
        XCTAssertEqual(productivityMetricsStore.snapshot.suggestionsAccepted, 0)
        XCTAssertEqual(productivityMetricsStore.snapshot.suggestionsDismissed, 0)
        XCTAssertNil(productivityMetricsStore.snapshot.averageBackendLatencyMs)
        XCTAssertNil(productivityMetricsStore.snapshot.lastLatencyReport)
        XCTAssertFalse(remoteConsentStore.hasConsent(for: .remoteBackend, remoteBaseURL: backendSettings.remoteBaseURL))
        XCTAssertEqual(debugArtifactStore.artifactCount(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: debugDirectory.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: completionTraceDirectory.path))
        XCTAssertFalse(pasteboardRecoveryStore.hasPendingSnapshot())
        XCTAssertEqual(debugOptionsStore.load(), .normal)

        XCTAssertTrue(privacySettings.collectionEnabled)
        XCTAssertTrue(privacySettings.clipboardContextEnabled)
        XCTAssertTrue(privacySettings.screenContextEnabled)
        XCTAssertTrue(privacySettings.productivityMetricsEnabled)
        XCTAssertFalse(privacySettings.localPersonalizationEnabled)
        XCTAssertEqual(privacySettings.perAppRules["com.apple.TextEdit"], false)
        XCTAssertEqual(privacySettings.perDomainRules["docs.google.com"], false)
        XCTAssertEqual(compatibilitySettingsStore.loadModeOverrides()["com.apple.TextEdit"], .manualOnly)
        XCTAssertEqual(compatibilitySettingsStore.loadDomainModeOverrides()["docs.google.com/document/d/example"], .disabled)
        XCTAssertTrue(FileManager.default.fileExists(atPath: operationalFile.path))

        let loadedBackendSettings = backendSettingsStore.load(localRuntimeState: .unavailableInBuild)
        XCTAssertEqual(loadedBackendSettings.remoteBaseURL, backendSettings.remoteBaseURL)
        XCTAssertEqual(loadedBackendSettings.remoteAPIKey, "backend-api-key-material")
        XCTAssertEqual(loadedBackendSettings.remoteModel, backendSettings.remoteModel)
        XCTAssertEqual(loadedBackendSettings.localConfiguration.modelPath, backendSettings.localConfiguration.modelPath)
        XCTAssertEqual(loadedBackendSettings.localConfiguration.maxRAMBytes, backendSettings.localConfiguration.maxRAMBytes)
        XCTAssertTrue(loadedBackendSettings.fallbackToRemoteOnLocalFailure)
        XCTAssertTrue(loadedBackendSettings.fallbackToRemoteOnAppleIntelligenceFailure)
        XCTAssertFalse(loadedBackendSettings.multiSuggestionEnabled)
    }

    private func utcCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func deleteKeychainItem(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(query as CFDictionary)
    }
}

private final class FailingRemoveFileManager: FileManager, @unchecked Sendable {
    override func removeItem(at URL: URL) throws {
        throw CocoaError(.fileWriteUnknown)
    }
}
