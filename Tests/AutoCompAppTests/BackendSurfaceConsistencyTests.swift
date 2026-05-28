import AutoCompCore
@testable import AutoCompApp
import Foundation
import XCTest

final class BackendSurfaceConsistencyTests: XCTestCase {
    private let remoteURL = "http://100.98.1.45:8000"
    private let modelPath = "/snapshot/model.gguf"
    private let missingModelPath = "/snapshot/missing.gguf"
    private let allocationFailure = "Local model allocation failed: memory limit exceeded."
    private let appleFailure = "FoundationModels request failed."

    func testBackendSurfaceSnapshotsStayAligned() throws {
        XCTAssertEqual(actualSnapshots(), try expectedSnapshots())
    }

    func testDisabledSourcePolicyNeverClaimsRemoteExposure() {
        for settings in representativeSettings() {
            XCTAssertEqual(settings.remoteBackendExposureTitle(sourceEnabled: false), "No; source is off.")
        }
    }

    func testDocumentationUsesSettingsTerminologyForTextLeavingMac() throws {
        let packageRoot = try packageRoot()
        let settingsSource = try String(
            contentsOf: packageRoot.appendingPathComponent("Sources/AutoCompApp/Views/SettingsRootView.swift"),
            encoding: .utf8
        )
        let readme = try String(contentsOf: packageRoot.appendingPathComponent("README.md"), encoding: .utf8)
        let privacyPolicy = try String(
            contentsOf: packageRoot.appendingPathComponent("Docs/PrivacyPolicy.md"),
            encoding: .utf8
        )

        for requiredText in [
            "Data leaves this Mac",
            "Remote fallback",
            "Remote OpenAI-compatible",
            "Local Llama",
            "Apple Intelligence",
            "autocomplete text may be sent"
        ] {
            XCTAssertTrue(settingsSource.contains(requiredText), "Settings missing \(requiredText)")
            XCTAssertTrue(readme.contains(requiredText), "README missing \(requiredText)")
            XCTAssertTrue(privacyPolicy.contains(requiredText), "Privacy policy missing \(requiredText)")
        }
    }

    private func actualSnapshots() -> [BackendSurfaceSnapshot] {
        [
            surfaceSnapshot(
                name: "remote-backend-active",
                settings: CompletionBackendSettings(remoteBaseURL: remoteURL)
            ),
            surfaceSnapshot(
                name: "local-runtime-unavailable",
                settings: CompletionBackendSettings(
                    engineKind: .localLlama,
                    remoteBaseURL: remoteURL,
                    localModelPath: missingModelPath,
                    localRuntimeState: .unavailableInBuild
                ),
                fileExists: { _ in false }
            ),
            surfaceSnapshot(
                name: "local-available-no-model",
                settings: CompletionBackendSettings(
                    engineKind: .localLlama,
                    remoteBaseURL: remoteURL,
                    localModelPath: "",
                    localRuntimeState: .available
                ),
                fileExists: { _ in false }
            ),
            surfaceSnapshot(
                name: "local-unloaded-with-model",
                settings: localSettings(),
                fileExists: modelExists,
                loadStatus: LocalLlamaRuntimeStatus(state: .unloaded, modelPath: modelPath)
            ),
            surfaceSnapshot(
                name: "local-loading-with-model",
                settings: localSettings(),
                fileExists: modelExists,
                loadStatus: LocalLlamaRuntimeStatus(state: .loading, modelPath: modelPath)
            ),
            surfaceSnapshot(
                name: "local-loaded-with-model",
                settings: localSettings(),
                fileExists: modelExists,
                loadStatus: LocalLlamaRuntimeStatus(state: .loaded, modelPath: modelPath)
            ),
            surfaceSnapshot(
                name: "local-failed-allocation",
                settings: localSettings(),
                fileExists: modelExists,
                loadStatus: LocalLlamaRuntimeStatus(
                    state: .failed,
                    modelPath: modelPath,
                    message: allocationFailure
                )
            ),
            surfaceSnapshot(
                name: "local-loaded-with-remote-fallback",
                settings: localSettings(fallback: true),
                fileExists: modelExists,
                loadStatus: LocalLlamaRuntimeStatus(state: .loaded, modelPath: modelPath),
                diagnostics: diagnostics(
                    requestedKind: .localLlama,
                    deliveredKind: .remote,
                    fallbackErrorDescription: allocationFailure
                )
            ),
            surfaceSnapshot(
                name: "apple-unavailable",
                settings: CompletionBackendSettings(
                    engineKind: .appleIntelligence,
                    remoteBaseURL: remoteURL
                ),
                appleAvailability: appleUnavailable
            ),
            surfaceSnapshot(
                name: "apple-available-without-fallback",
                settings: CompletionBackendSettings(
                    engineKind: .appleIntelligence,
                    remoteBaseURL: remoteURL
                ),
                appleAvailability: appleAvailable
            ),
            surfaceSnapshot(
                name: "apple-available-with-remote-fallback",
                settings: CompletionBackendSettings(
                    engineKind: .appleIntelligence,
                    remoteBaseURL: remoteURL,
                    fallbackToRemoteOnAppleIntelligenceFailure: true
                ),
                appleAvailability: appleAvailable,
                diagnostics: diagnostics(
                    requestedKind: .appleIntelligence,
                    deliveredKind: .remote,
                    fallbackErrorDescription: appleFailure
                )
            )
        ]
    }

    private func surfaceSnapshot(
        name: String,
        settings: CompletionBackendSettings,
        fileExists: @escaping (String) -> Bool = { _ in false },
        loadStatus: LocalLlamaRuntimeStatus = .unloaded,
        appleAvailability: AppleFoundationModelAvailability = AppleFoundationModelAvailability(
            isAvailable: false,
            statusTitle: "Unavailable",
            detail: "FoundationModels requires macOS 26.0 or newer."
        ),
        diagnostics: SuggestionDiagnostics? = nil
    ) -> BackendSurfaceSnapshot {
        let localDiagnostic = settings.engineKind == .localLlama
            ? settings.localDiagnostic(fileExists: fileExists, loadStatus: loadStatus)
            : nil
        let appleDiagnostic = settings.engineKind == .appleIntelligence
            ? settings.appleIntelligenceDiagnostic(availability: appleAvailability)
            : nil

        return BackendSurfaceSnapshot(
            name: name,
            summary: settings.backendSummary(fileExists: fileExists, appleAvailability: appleAvailability),
            requestDestination: settings.requestDestinationTitle,
            dataLeavesThisMac: settings.dataLeavesDeviceTitle(
                fileExists: fileExists,
                appleAvailability: appleAvailability
            ),
            remoteFallback: settings.remoteFallbackTitle,
            remoteFallbackWarning: settings.remoteFallbackWarning,
            sourcePolicyRemoteBackend: settings.remoteBackendExposureTitle(sourceEnabled: true),
            localRuntime: localDiagnostic?.runtimeTitle,
            localModelFile: localDiagnostic?.modelFileTitle,
            localLoadState: localDiagnostic?.loadStateTitle,
            localLastError: localDiagnostic?.lastErrorTitle,
            localFallback: localDiagnostic?.fallbackTitle,
            localUsable: localDiagnostic?.isUsable,
            appleAvailability: appleDiagnostic?.availabilityTitle,
            appleRequirement: appleDiagnostic?.requirementTitle,
            appleFallback: appleDiagnostic?.fallbackTitle,
            appleUsable: appleDiagnostic?.isUsable,
            diagnosticsLastBackend: diagnostics?.backend.lastUsedTitle,
            diagnosticsLocalError: diagnostics?.backend.errorTitle(for: .localLlama),
            diagnosticsAppleError: diagnostics?.backend.errorTitle(for: .appleIntelligence),
            diagnosticsRemoteError: diagnostics?.backend.errorTitle(for: .remote)
        )
    }

    private func localSettings(fallback: Bool = false) -> CompletionBackendSettings {
        CompletionBackendSettings(
            engineKind: .localLlama,
            remoteBaseURL: remoteURL,
            localModelPath: modelPath,
            localRuntimeState: .available,
            fallbackToRemoteOnLocalFailure: fallback
        )
    }

    private func modelExists(_ path: String) -> Bool {
        path == modelPath
    }

    private var appleUnavailable: AppleFoundationModelAvailability {
        AppleFoundationModelAvailability(
            isAvailable: false,
            statusTitle: "Unavailable",
            detail: "FoundationModels requires macOS 26.0 or newer."
        )
    }

    private var appleAvailable: AppleFoundationModelAvailability {
        AppleFoundationModelAvailability(
            isAvailable: true,
            statusTitle: "Available",
            detail: "FoundationModels system language model is available."
        )
    }

    private func diagnostics(
        requestedKind: CompletionEngineKind,
        deliveredKind: CompletionEngineKind,
        fallbackErrorDescription: String
    ) -> SuggestionDiagnostics {
        var diagnostics = SuggestionDiagnostics()
        diagnostics.recordBackendRequest(
            policy: CompletionRoutingPolicy(activeKind: requestedKind, fallbackKind: deliveredKind)
        )
        diagnostics.recordBackendSuccess(
            rawText: nil,
            normalizedText: "redacted",
            collectionAllowed: false,
            route: CompletionRoute(
                requestedKind: requestedKind,
                deliveredKind: deliveredKind,
                fallbackErrorDescription: fallbackErrorDescription
            )
        )
        return diagnostics
    }

    private func representativeSettings() -> [CompletionBackendSettings] {
        [
            CompletionBackendSettings(remoteBaseURL: remoteURL),
            localSettings(),
            localSettings(fallback: true),
            CompletionBackendSettings(engineKind: .appleIntelligence, remoteBaseURL: remoteURL),
            CompletionBackendSettings(
                engineKind: .appleIntelligence,
                remoteBaseURL: remoteURL,
                fallbackToRemoteOnAppleIntelligenceFailure: true
            )
        ]
    }

    private func expectedSnapshots() throws -> [BackendSurfaceSnapshot] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/BackendSurfaceConsistency/snapshots.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([BackendSurfaceSnapshot].self, from: data)
    }

    private func packageRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
        }
        throw NSError(domain: "BackendSurfaceConsistencyTests", code: 1)
    }
}

private struct BackendSurfaceSnapshot: Codable, Equatable {
    let name: String
    let summary: String
    let requestDestination: String
    let dataLeavesThisMac: String
    let remoteFallback: String
    let remoteFallbackWarning: String?
    let sourcePolicyRemoteBackend: String
    let localRuntime: String?
    let localModelFile: String?
    let localLoadState: String?
    let localLastError: String?
    let localFallback: String?
    let localUsable: Bool?
    let appleAvailability: String?
    let appleRequirement: String?
    let appleFallback: String?
    let appleUsable: Bool?
    let diagnosticsLastBackend: String?
    let diagnosticsLocalError: String?
    let diagnosticsAppleError: String?
    let diagnosticsRemoteError: String?
}
