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
            fallbackToRemoteOnLocalFailure: false
        )

        service.save(settings)
        let loaded = service.load()

        XCTAssertEqual(loaded, settings)
        XCTAssertEqual(defaults.string(forKey: "completionBackend.kind"), CompletionEngineKind.remote.rawValue)
        XCTAssertEqual(defaults.string(forKey: "completionBackend.localLastError"), "previous local failure")
        XCTAssertEqual(loaded.summary, "Remote backend: test-model at http://127.0.0.1:8000")
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
        let settings = service.load()

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

    func testAppleIntelligenceSummaryDescribesSelectedBackend() {
        let settings = CompletionBackendSettings(engineKind: .appleIntelligence)

        XCTAssertEqual(settings.summary, "Apple Intelligence backend with remote fallback")
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
