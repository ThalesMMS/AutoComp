import AutoCompCore
@testable import AutoCompApp
import Security
import XCTest

final class CompletionBackendConfigurationServiceTests: XCTestCase {
    func testRemoteSettingsSaveAndLoadWithoutVisibleMigration() {
        let defaultsName = "CompletionBackendConfigurationServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
        }

        let keychainService = "com.autocomp.tests.\(UUID().uuidString)"
        defer {
            deleteKeychainItem(service: keychainService, account: "remote-api-key")
        }
        let service = CompletionBackendConfigurationService(
            defaults: defaults,
            keychainService: keychainService,
            keychainAccount: "remote-api-key"
        )
        let settings = CompletionBackendSettings(
            remoteBaseURL: "http://127.0.0.1:8000",
            remoteAPIKey: "secret",
            remoteModel: "test-model",
            localModelPath: "/tmp/autocomp-local.gguf",
            localMaxRAMBytes: 1024,
            localLastError: "previous local failure",
            fallbackToRemoteOnLocalFailure: false,
            multiSuggestionEnabled: false
        )

        service.save(settings)
        let loaded = service.load(localRuntimeState: settings.localRuntimeState)

        XCTAssertEqual(loaded, settings)
        XCTAssertEqual(defaults.string(forKey: "completionBackend.kind"), CompletionEngineKind.remote.rawValue)
        XCTAssertEqual(defaults.string(forKey: "completionBackend.localLastError"), "previous local failure")
        XCTAssertFalse(defaults.bool(forKey: "completionBackend.multiSuggestionEnabled"))
        XCTAssertEqual(loaded.summary, "Remote backend: test-model at http://127.0.0.1:8000")
        XCTAssertEqual(loaded.requestDestinationTitle, "Remote: test-model at http://127.0.0.1:8000")
        XCTAssertTrue(loaded.dataLeavesDeviceTitle.contains("sent to http://127.0.0.1:8000"))
    }

    func testRemoteSettingsLoadLegacyDomainAndSaveToBothDomains() {
        let canonicalName = "CompletionBackendConfigurationServiceTests.canonical.\(UUID().uuidString)"
        let legacyName = "CompletionBackendConfigurationServiceTests.legacy.\(UUID().uuidString)"
        let canonicalDefaults = UserDefaults(suiteName: canonicalName)!
        let legacyDefaults = UserDefaults(suiteName: legacyName)!
        defer {
            canonicalDefaults.removePersistentDomain(forName: canonicalName)
            legacyDefaults.removePersistentDomain(forName: legacyName)
        }

        legacyDefaults.set(CompletionEngineKind.remote.rawValue, forKey: "completionBackend.kind")
        legacyDefaults.set("http://192.168.100.67:8000/v1", forKey: "completionBackend.remoteBaseURL")
        legacyDefaults.set("default", forKey: "completionBackend.remoteModel")

        let service = CompletionBackendConfigurationService(
            defaults: canonicalDefaults,
            mirroredDefaults: [legacyDefaults],
            keychainService: "com.autocomp.tests.\(UUID().uuidString)",
            keychainAccount: "remote-api-key"
        )

        let migrated = service.load(localRuntimeState: .unavailableInBuild)
        XCTAssertEqual(migrated.remoteBaseURL, "http://192.168.100.67:8000/v1")
        XCTAssertEqual(migrated.remoteModel, "default")

        let updated = CompletionBackendSettings(
            remoteBaseURL: "http://192.168.100.67:8000/v1",
            remoteModel: "default",
            fallbackToRemoteOnAppleIntelligenceFailure: true
        )
        service.save(updated)

        XCTAssertEqual(canonicalDefaults.string(forKey: "completionBackend.remoteBaseURL"), "http://192.168.100.67:8000/v1")
        XCTAssertEqual(canonicalDefaults.string(forKey: "completionBackend.remoteModel"), "default")
        XCTAssertEqual(legacyDefaults.string(forKey: "completionBackend.remoteBaseURL"), "http://192.168.100.67:8000/v1")
        XCTAssertEqual(legacyDefaults.string(forKey: "completionBackend.remoteModel"), "default")
        XCTAssertTrue(canonicalDefaults.bool(forKey: "completionBackend.fallbackToRemoteOnAppleIntelligenceFailure"))
        XCTAssertTrue(legacyDefaults.bool(forKey: "completionBackend.fallbackToRemoteOnAppleIntelligenceFailure"))
    }

    func testInternalLocalSettingsLoadFromDefaults() {
        let defaultsName = "CompletionBackendConfigurationServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
        }
        defaults.set(CompletionEngineKind.localLlama.rawValue, forKey: "completionBackend.kind")
        defaults.set("/tmp/model.gguf", forKey: "completionBackend.localModelPath")
        defaults.set(UInt64(2_048), forKey: "completionBackend.localMaxRAMBytes")
        defaults.set("llama load failed", forKey: "completionBackend.localLastError")
        defaults.set(true, forKey: "completionBackend.fallbackToRemoteOnLocalFailure")
        defaults.set(false, forKey: "completionBackend.fallbackToRemoteOnAppleIntelligenceFailure")

        let service = CompletionBackendConfigurationService(
            defaults: defaults,
            keychainService: "com.autocomp.tests.\(UUID().uuidString)",
            keychainAccount: "remote-api-key"
        )
        let settings = service.load(localRuntimeState: .unavailableInBuild)

        XCTAssertEqual(settings.engineKind, .localLlama)
        XCTAssertEqual(settings.localConfiguration.modelPath, "/tmp/model.gguf")
        XCTAssertEqual(settings.localConfiguration.maxRAMBytes, 2_048)
        XCTAssertEqual(settings.localLastError, "llama load failed")
        XCTAssertTrue(settings.fallbackToRemoteOnLocalFailure)
        XCTAssertFalse(settings.fallbackToRemoteOnAppleIntelligenceFailure)
        XCTAssertEqual(
            settings.summary,
            "Local Llama backend unavailable: Unavailable: Local runtime is unavailable in this app build.; Missing at /tmp/model.gguf"
        )
    }

    func testLoadUsesResolvedLocalRuntimeState() throws {
        let defaultsName = "CompletionBackendConfigurationServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
        }
        let modelURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("autocomp-\(UUID().uuidString).gguf")
        try Data("fake model".utf8).write(to: modelURL)
        defer {
            try? FileManager.default.removeItem(at: modelURL)
        }
        defaults.set(CompletionEngineKind.localLlama.rawValue, forKey: "completionBackend.kind")
        defaults.set(modelURL.path, forKey: "completionBackend.localModelPath")

        let service = CompletionBackendConfigurationService(
            defaults: defaults,
            keychainService: "com.autocomp.tests.\(UUID().uuidString)",
            keychainAccount: "remote-api-key"
        )

        let available = service.load(localRuntimeState: .available)
        let unavailable = service.load(localRuntimeState: .unavailableInBuild)

        XCTAssertEqual(available.localRuntimeState, .available)
        XCTAssertEqual(unavailable.localRuntimeState, .unavailableInBuild)
        XCTAssertEqual(available.summary, "Local Llama backend: available at \(modelURL.path)")
        XCTAssertEqual(
            unavailable.summary,
            "Local Llama backend unavailable: Unavailable: Local runtime is unavailable in this app build.; Found at \(modelURL.path)"
        )
    }

    func testAppleIntelligenceSummaryDescribesSelectedBackend() {
        let settings = CompletionBackendSettings(engineKind: .appleIntelligence)
        let diagnostic = settings.appleIntelligenceDiagnostic(availability: AppleFoundationModelAvailability(
            isAvailable: false,
            statusTitle: "Unavailable",
            detail: "FoundationModels requires macOS 26.0 or newer."
        ))

        XCTAssertTrue(settings.summary.contains("Apple Intelligence backend"))
        XCTAssertEqual(diagnostic.availabilityTitle, "Unavailable")
        XCTAssertEqual(diagnostic.requirementTitle, "FoundationModels requires macOS 26.0 or newer.")
        XCTAssertEqual(diagnostic.fallbackTitle, "Remote fallback disabled")
        XCTAssertEqual(settings.remoteFallbackTitle, "Disabled")
        XCTAssertNil(settings.remoteFallbackWarning)
        XCTAssertFalse(diagnostic.isUsable)
    }

    func testRemoteFallbackDefaultsToOptIn() {
        let settings = CompletionBackendSettings(engineKind: .localLlama)

        XCTAssertFalse(settings.fallbackToRemoteOnLocalFailure)
        XCTAssertFalse(settings.fallbackToRemoteOnAppleIntelligenceFailure)
        XCTAssertEqual(settings.remoteFallbackTitle, "Disabled")
        XCTAssertEqual(settings.dataLeavesDeviceTitle, "No, local completion requests stay on this Mac.")
    }

    func testRemoteFallbackWarningExplainsDataLeavingMac() {
        let settings = CompletionBackendSettings(
            engineKind: .localLlama,
            remoteBaseURL: "http://127.0.0.1:8000",
            fallbackToRemoteOnLocalFailure: true
        )

        XCTAssertEqual(settings.remoteFallbackTitle, "Enabled after local failure")
        XCTAssertEqual(
            settings.remoteFallbackWarning,
            "Remote fallback is enabled: if local completion fails, autocomplete text may be sent to http://127.0.0.1:8000."
        )
    }

    func testAppleIntelligenceDiagnosticReflectsAvailableBackendAndFallbackOff() {
        let settings = CompletionBackendSettings(
            engineKind: .appleIntelligence,
            fallbackToRemoteOnAppleIntelligenceFailure: false
        )

        let diagnostic = settings.appleIntelligenceDiagnostic(availability: AppleFoundationModelAvailability(
            isAvailable: true,
            statusTitle: "Available",
            detail: "FoundationModels system language model is available."
        ))

        XCTAssertEqual(diagnostic.availabilityTitle, "Available")
        XCTAssertEqual(diagnostic.requirementTitle, "FoundationModels system language model is available.")
        XCTAssertEqual(diagnostic.fallbackTitle, "Remote fallback disabled")
        XCTAssertTrue(diagnostic.isUsable)
    }

    func testLocalSummaryDifferentiatesAvailableAndUnavailableStates() throws {
        let modelURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("autocomp-\(UUID().uuidString).gguf")
        try Data("fake model".utf8).write(to: modelURL)
        defer {
            try? FileManager.default.removeItem(at: modelURL)
        }

        let available = CompletionBackendSettings(
            engineKind: .localLlama,
            localModelPath: modelURL.path,
            localRuntimeState: .available
        )
        let missingModel = CompletionBackendSettings(
            engineKind: .localLlama,
            localModelPath: modelURL.appendingPathExtension("missing").path,
            localRuntimeState: .available
        )
        let unavailableRuntime = CompletionBackendSettings(
            engineKind: .localLlama,
            localModelPath: modelURL.path,
            localRuntimeState: .unavailableInBuild
        )

        XCTAssertEqual(available.summary, "Local Llama backend: available at \(modelURL.path)")
        XCTAssertEqual(
            missingModel.summary,
            "Local Llama backend unavailable: Available; Missing at \(modelURL.appendingPathExtension("missing").path)"
        )
        XCTAssertEqual(
            unavailableRuntime.summary,
            "Local Llama backend unavailable: Unavailable: Local runtime is unavailable in this app build.; Found at \(modelURL.path)"
        )
    }

    func testLocalDiagnosticReportsFallbackLastErrorAndMemoryLimit() {
        let settings = CompletionBackendSettings(
            engineKind: .localLlama,
            localModelPath: "/tmp/missing.gguf",
            localMaxRAMBytes: 2_048,
            localRuntimeState: .available,
            localLastError: "decode failed",
            fallbackToRemoteOnLocalFailure: false
        )

        let diagnostic = settings.localDiagnostic(fileExists: { _ in false })

        XCTAssertEqual(diagnostic.runtimeTitle, "Available")
        XCTAssertEqual(diagnostic.modelFileTitle, "Missing at /tmp/missing.gguf")
        XCTAssertEqual(diagnostic.loadStateTitle, "Blocked")
        XCTAssertEqual(diagnostic.lastErrorTitle, "decode failed")
        XCTAssertEqual(diagnostic.fallbackTitle, "Remote fallback disabled")
        XCTAssertFalse(diagnostic.isUsable)
    }

    func testUnknownEngineKindFallsBackToRemote() {
        let defaultsName = "CompletionBackendConfigurationServiceTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
        }
        defaults.set("future-mode", forKey: "completionBackend.kind")

        let service = CompletionBackendConfigurationService(
            defaults: defaults,
            keychainService: "com.autocomp.tests.\(UUID().uuidString)",
            keychainAccount: "remote-api-key"
        )

        XCTAssertEqual(service.load().engineKind, .remote)
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
