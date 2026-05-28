import AutoCompCore
@testable import AutoCompApp
import XCTest

final class RemoteCompletionConsentStoreTests: XCTestCase {
    func testConsentPersistsPerScopeAndEndpoint() throws {
        let defaultsName = "RemoteCompletionConsentStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
        }
        let store = RemoteCompletionConsentStore(defaults: defaults, key: "consent")

        store.grantConsent(for: .remoteBackend, remoteBaseURL: "HTTP://127.0.0.1:8000/")

        XCTAssertTrue(store.hasConsent(for: .remoteBackend, remoteBaseURL: "http://127.0.0.1:8000"))
        XCTAssertFalse(store.hasConsent(for: .remoteFallback, remoteBaseURL: "http://127.0.0.1:8000"))
        XCTAssertFalse(store.hasConsent(for: .remoteBackend, remoteBaseURL: "http://127.0.0.1:9000"))

        let reloadedStore = RemoteCompletionConsentStore(defaults: defaults, key: "consent")
        XCTAssertTrue(reloadedStore.hasConsent(for: .remoteBackend, remoteBaseURL: "http://127.0.0.1:8000"))

        reloadedStore.reset()

        XCTAssertFalse(store.hasConsent(for: .remoteBackend, remoteBaseURL: "http://127.0.0.1:8000"))
    }

    func testConsentEndpointStripsCredentialsQueryAndFragmentBeforePersistence() throws {
        let defaultsName = "RemoteCompletionConsentStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: defaultsName))
        defer {
            defaults.removePersistentDomain(forName: defaultsName)
        }
        let store = RemoteCompletionConsentStore(defaults: defaults, key: "consent")

        store.grantConsent(
            for: .remoteBackend,
            remoteBaseURL: "HTTPS://user:secret@api.example.com/v1/?token=private#fragment"
        )

        XCTAssertTrue(store.hasConsent(for: .remoteBackend, remoteBaseURL: "https://api.example.com/v1"))
        let persisted = try XCTUnwrap(defaults.data(forKey: "consent"))
        let persistedText = String(decoding: persisted, as: UTF8.self)
        XCTAssertTrue(persistedText.contains("api.example.com"))
        XCTAssertFalse(persistedText.contains("user"))
        XCTAssertFalse(persistedText.contains("secret"))
        XCTAssertFalse(persistedText.contains("token=private"))
        XCTAssertFalse(persistedText.contains("fragment"))
    }

    func testDestinationKindClassifiesLocalLanAndCloudEndpoints() {
        XCTAssertEqual(
            RemoteCompletionConsentStore.destinationKindTitle(for: "http://127.0.0.1:8000"),
            "Local on this Mac"
        )
        XCTAssertEqual(
            RemoteCompletionConsentStore.destinationKindTitle(for: "http://100.98.1.45:8000"),
            "LAN/private network"
        )
        XCTAssertEqual(
            RemoteCompletionConsentStore.destinationKindTitle(for: "http://192.168.1.20:8000"),
            "LAN/private network"
        )
        XCTAssertEqual(
            RemoteCompletionConsentStore.destinationKindTitle(for: "https://api.example.com/v1"),
            "Cloud or public internet"
        )
    }

    func testBackendSettingsExposeRemoteConsentRequirementsByMode() {
        let remote = CompletionBackendSettings(
            engineKind: .remote,
            remoteBaseURL: "http://100.98.1.45:8000"
        )
        let localOnly = CompletionBackendSettings(
            engineKind: .localLlama,
            fallbackToRemoteOnLocalFailure: false
        )
        let localFallback = CompletionBackendSettings(
            engineKind: .localLlama,
            remoteBaseURL: "http://100.98.1.45:8000",
            fallbackToRemoteOnLocalFailure: true
        )
        let appleOnly = CompletionBackendSettings(
            engineKind: .appleIntelligence,
            fallbackToRemoteOnAppleIntelligenceFailure: false
        )
        let appleFallback = CompletionBackendSettings(
            engineKind: .appleIntelligence,
            remoteBaseURL: "http://100.98.1.45:8000",
            fallbackToRemoteOnAppleIntelligenceFailure: true
        )

        XCTAssertEqual(remote.remoteConsentRequirements.map(\.scope), [.remoteBackend])
        XCTAssertEqual(localFallback.remoteConsentRequirements.map(\.scope), [.remoteFallback])
        XCTAssertEqual(appleFallback.remoteConsentRequirements.map(\.scope), [.remoteFallback])
        XCTAssertTrue(localOnly.remoteConsentRequirements.isEmpty)
        XCTAssertTrue(appleOnly.remoteConsentRequirements.isEmpty)
        XCTAssertTrue(localOnly.remoteConsentLocalOnlyDescription.contains("stays on this Mac"))
        XCTAssertTrue(appleOnly.remoteConsentLocalOnlyDescription.contains("No remote endpoint"))
    }
}
