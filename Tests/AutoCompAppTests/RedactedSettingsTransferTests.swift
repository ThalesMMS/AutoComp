import AutoCompCore
@testable import AutoCompApp
import XCTest

final class RedactedSettingsTransferTests: XCTestCase {
    func testExportOmitsSecretsContentAndLocalModelPath() throws {
        let privacy = PrivacySettings(
            collectionEnabled: true,
            clipboardContextEnabled: true,
            screenContextEnabled: true,
            productivityMetricsEnabled: false,
            writingPreferences: WritingPreferences(enabled: true, rules: ["SECRET writing rule"]),
            perAppRules: ["com.example.Secret": false],
            perDomainRules: ["docs.example.com": false]
        )
        let backend = CompletionBackendSettings(
            engineKind: .localLlama,
            remoteBaseURL: "https://user:SECRET_PASSWORD@example.com/v1?api_key=SECRET_QUERY#fragment",
            remoteAPIKey: "SECRET_API_KEY",
            remoteModel: "default",
            localModelPath: "/Users/thales/private/secret-model.gguf",
            fallbackToRemoteOnLocalFailure: true
        )

        let package = RedactedSettingsTransfer.package(
            compatibilityOverrides: [
                "com.apple.TextEdit": .automatic,
                "domain:docs.example.com": .manualOnly
            ],
            privacySettings: privacy,
            shortcutSettings: .defaults,
            backendSettings: backend,
            safeOverlayModeEnabled: true,
            exportedAt: Date(timeIntervalSince1970: 1)
        )
        let body = String(data: try RedactedSettingsTransfer.encodedData(for: package), encoding: .utf8) ?? ""

        XCTAssertEqual(package.backend.remoteBaseURL, "https://example.com/v1")
        XCTAssertTrue(body.contains("secret-model.gguf"))
        XCTAssertTrue(body.contains("docs.example.com"))
        XCTAssertFalse(body.contains("SECRET_API_KEY"))
        XCTAssertFalse(body.contains("SECRET_PASSWORD"))
        XCTAssertFalse(body.contains("SECRET_QUERY"))
        XCTAssertFalse(body.contains("fragment"))
        XCTAssertFalse(body.contains("/Users/thales/private"))
        XCTAssertFalse(body.contains("SECRET writing rule"))
        XCTAssertFalse(body.contains("com.example.Secret"))
        XCTAssertFalse(body.contains("telemetry"))
        XCTAssertFalse(body.contains("DebugArtifacts"))
    }

    func testImportRejectsInvalidSchemaAndUnsupportedVersion() throws {
        let validPackage = makePackage()

        var invalidSchema = validPackage
        invalidSchema.schema = "example.invalid"
        XCTAssertThrowsError(
            try RedactedSettingsTransfer.decodedPackage(
                from: RedactedSettingsTransfer.encodedData(for: invalidSchema)
            )
        ) { error in
            XCTAssertEqual(error as? RedactedSettingsTransferError, .invalidSchema("example.invalid"))
        }

        var unsupportedVersion = validPackage
        unsupportedVersion.version = 99
        XCTAssertThrowsError(
            try RedactedSettingsTransfer.decodedPackage(
                from: RedactedSettingsTransfer.encodedData(for: unsupportedVersion)
            )
        ) { error in
            XCTAssertEqual(error as? RedactedSettingsTransferError, .unsupportedVersion(99))
        }
    }

    func testApplyHelpersPreserveSecretsAndSensitiveLocalState() {
        let currentPrivacy = PrivacySettings(
            collectionEnabled: false,
            clipboardContextEnabled: false,
            screenContextEnabled: false,
            telemetryEnabled: true,
            personalizationStrength: 0.8,
            writingPreferences: WritingPreferences(enabled: true, rules: ["keep local writing rule"]),
            perAppRules: ["com.apple.TextEdit": true],
            perDomainRules: ["old.example.com": true]
        )
        let importedPrivacy = RedactedPrivacySettings(
            collectionEnabled: true,
            clipboardContextEnabled: true,
            screenContextEnabled: true,
            productivityMetricsEnabled: false,
            domainRules: ["new.example.com": false]
        )

        let updatedPrivacy = RedactedSettingsTransfer.privacySettings(
            applying: importedPrivacy,
            to: currentPrivacy
        )

        XCTAssertEqual(updatedPrivacy.collectionEnabled, true)
        XCTAssertEqual(updatedPrivacy.clipboardContextEnabled, true)
        XCTAssertEqual(updatedPrivacy.screenContextEnabled, true)
        XCTAssertEqual(updatedPrivacy.productivityMetricsEnabled, false)
        XCTAssertEqual(updatedPrivacy.perDomainRules, ["new.example.com": false])
        XCTAssertEqual(updatedPrivacy.perAppRules, ["com.apple.TextEdit": true])
        XCTAssertEqual(updatedPrivacy.personalizationStrength, 0.8)
        XCTAssertEqual(updatedPrivacy.writingPreferences.rules, ["keep local writing rule"])
        XCTAssertFalse(updatedPrivacy.telemetryEnabled)

        let currentBackend = CompletionBackendSettings(
            engineKind: .remote,
            remoteBaseURL: "https://old.example.com",
            remoteAPIKey: "SECRET_API_KEY",
            remoteModel: "old-model",
            localModelPath: "/Users/thales/private/current.gguf",
            localMaxRAMBytes: 1
        )
        let importedBackend = RedactedBackendSettings(
            engineKind: .appleIntelligence,
            remoteBaseURL: "https://user:SECRET_PASSWORD@new.example.com/v1?api_key=SECRET_QUERY#fragment",
            remoteModel: "new-model",
            localModelBasename: "imported.gguf",
            localMaxRAMBytes: 2,
            fallbackToRemoteOnLocalFailure: true,
            fallbackToRemoteOnAppleIntelligenceFailure: true,
            multiSuggestionEnabled: true,
            stopSequences: CompletionStopSequences(
                continuation: ["</stop>"],
                fillInMiddle: ["</fim>"]
            )
        )

        let updatedBackend = RedactedSettingsTransfer.backendSettings(
            applying: importedBackend,
            to: currentBackend
        )

        XCTAssertEqual(updatedBackend.engineKind, .appleIntelligence)
        XCTAssertEqual(updatedBackend.remoteBaseURL, "https://new.example.com/v1")
        XCTAssertEqual(updatedBackend.remoteModel, "new-model")
        XCTAssertEqual(updatedBackend.localMaxRAMBytes, 2)
        XCTAssertEqual(updatedBackend.remoteAPIKey, "SECRET_API_KEY")
        XCTAssertEqual(updatedBackend.localModelPath, "/Users/thales/private/current.gguf")
    }

    func testPreviewDoesNotExposeSecrets() {
        let package = makePackage()
        let preview = RedactedSettingsTransfer.preview(
            package: package,
            currentCompatibilityOverrides: ["com.apple.TextEdit": .automatic],
            currentPrivacySettings: PrivacySettings(perDomainRules: ["old.example.com": true]),
            currentShortcutSettings: .defaults,
            currentBackendSettings: CompletionBackendSettings(
                remoteBaseURL: "https://old.example.com",
                remoteAPIKey: "SECRET_API_KEY",
                localModelPath: "/Users/thales/private/current.gguf"
            ),
            safeOverlayModeEnabled: false
        )
        let body = ([preview.summary] + preview.rows.flatMap { [$0.title, $0.currentValue, $0.importedValue] } + preview.warnings)
            .joined(separator: "\n")

        XCTAssertTrue(body.contains("Remote API key is not included"))
        XCTAssertTrue(body.contains("Local model path is not included"))
        XCTAssertFalse(body.contains("SECRET_API_KEY"))
        XCTAssertFalse(body.contains("/Users/thales/private"))
    }

    private func makePackage() -> RedactedSettingsPackage {
        RedactedSettingsPackage(
            exportedAt: Date(timeIntervalSince1970: 1),
            compatibility: RedactedCompatibilitySettings(
                appOverrides: ["com.apple.TextEdit": .automatic],
                domainOverrides: ["docs.example.com": .manualOnly]
            ),
            privacy: RedactedPrivacySettings(
                collectionEnabled: true,
                clipboardContextEnabled: true,
                screenContextEnabled: false,
                productivityMetricsEnabled: false,
                domainRules: ["docs.example.com": false]
            ),
            shortcuts: .defaults,
            overlay: RedactedOverlaySettings(safeModeEnabled: true),
            backend: RedactedBackendSettings(
                engineKind: .remote,
                remoteBaseURL: "https://new.example.com",
                remoteModel: "default",
                localModelBasename: "model.gguf",
                localMaxRAMBytes: 2,
                fallbackToRemoteOnLocalFailure: false,
                fallbackToRemoteOnAppleIntelligenceFailure: false,
                multiSuggestionEnabled: false,
                stopSequences: .conservativeDefault
            )
        )
    }
}
