@testable import AutoCompApp
import XCTest

final class AutoCompDebugTests: XCTestCase {
    func testRedactedSummaryDoesNotExposeSourceText() {
        let secret = "private prompt text 123"

        let summary = AutoCompLogger.redactedSummary(for: secret)
        let description = summary.description

        XCTAssertEqual(summary.characterCount, secret.count)
        XCTAssertEqual(summary.utf8ByteCount, secret.utf8.count)
        XCTAssertTrue(description.contains("chars="))
        XCTAssertTrue(description.contains("bytes="))
        XCTAssertTrue(description.contains("sha256="))
        XCTAssertFalse(description.contains("private prompt"))
        XCTAssertFalse(description.contains(secret))
    }

    func testDebugOptionsStoreDefaultsToOffAndRoundTrips() throws {
        let suiteName = "AutoCompDebugOptions-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let store = AutoCompDebugOptionsStore(defaults: defaults, key: "debug")

        XCTAssertEqual(store.load(), .normal)

        store.save(AutoCompDebugOptions(localDebugOptIn: true))

        XCTAssertEqual(store.load(), AutoCompDebugOptions(localDebugOptIn: true))
    }

    @MainActor
    func testOverlayRecoveryAdvisorRecommendsSafeModeAfterRepeatedFailures() throws {
        let suiteName = "AutoCompOverlayRecovery-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer {
            defaults.removePersistentDomain(forName: suiteName)
        }
        let advisor = OverlayRecoveryAdvisor(
            defaults: defaults,
            key: "overlayFailures",
            isSafeOverlayModeEnabled: { false }
        )

        XCTAssertFalse(advisor.shouldRecommendSafeOverlayMode)

        for _ in 0..<OverlayRecoveryAdvisor.failureThreshold {
            advisor.recordAdvancedOverlayFallback()
        }

        XCTAssertTrue(advisor.shouldRecommendSafeOverlayMode)
        XCTAssertTrue(advisor.recommendationMessage.contains("AUTOCOMP_SAFE_OVERLAY_MODE=1"))

        advisor.recordAdvancedOverlaySuccess()

        XCTAssertEqual(advisor.advancedOverlayFailureCount, 0)
        XCTAssertFalse(advisor.shouldRecommendSafeOverlayMode)
    }

    func testArtifactStoreRefusesSensitiveWritesWithoutOptIn() throws {
        let directory = temporaryDirectory()
        let store = DebugArtifactStore(directory: directory)

        let url = try store.saveSensitiveArtifact(
            named: "prompt",
            contents: "secret typed text",
            options: .normal
        )

        XCTAssertNil(url)
        XCTAssertEqual(store.artifactCount(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testArtifactStoreWritesWarningAndDeletesWhenOptedIn() throws {
        let directory = temporaryDirectory()
        let store = DebugArtifactStore(directory: directory)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let url = try XCTUnwrap(try store.saveSensitiveArtifact(
            named: "prompt / OCR",
            contents: "secret typed text",
            options: AutoCompDebugOptions(localDebugOptIn: true),
            createdAt: Date(timeIntervalSince1970: 42)
        ))

        let body = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(body.contains("may contain prompt, OCR, clipboard, or typed user content"))
        XCTAssertTrue(body.contains("secret typed text"))
        XCTAssertTrue(url.lastPathComponent.contains("prompt---OCR"))
        XCTAssertEqual(store.artifactCount(), 1)

        try store.deleteAll()

        XCTAssertEqual(store.artifactCount(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testArtifactStoreExportsLocalDebugLogBundle() throws {
        let directory = temporaryDirectory()
        let exportRoot = temporaryDirectory()
        let store = DebugArtifactStore(directory: directory)
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: exportRoot)
        }

        _ = try XCTUnwrap(try store.saveSensitiveArtifact(
            named: "prompt",
            contents: "secret typed text",
            options: AutoCompDebugOptions(localDebugOptIn: true),
            createdAt: Date(timeIntervalSince1970: 42)
        ))

        let exportURL = try store.exportDebugLogs(
            to: exportRoot,
            options: AutoCompDebugOptions(localDebugOptIn: true),
            createdAt: Date(timeIntervalSince1970: 84)
        )
        let summary = try String(
            contentsOf: exportURL.appendingPathComponent("debug-summary.txt"),
            encoding: .utf8
        )
        let artifacts = try FileManager.default.contentsOfDirectory(
            at: exportURL.appendingPathComponent("DebugArtifacts", isDirectory: true),
            includingPropertiesForKeys: nil
        )

        XCTAssertTrue(exportURL.lastPathComponent.hasPrefix("AutoComp-Debug-Logs-"))
        XCTAssertTrue(summary.contains("AutoComp local debug log export"))
        XCTAssertTrue(summary.contains("Debug artifact count: 1"))
        XCTAssertEqual(artifacts.count, 1)
        XCTAssertTrue(artifacts[0].lastPathComponent.contains("prompt"))
    }

    func testSuggestionDebugLoggerPersistsPlaygroundOnlyWhenOptedIn() throws {
        let directory = temporaryDirectory()
        let artifactStore = DebugArtifactStore(directory: directory)
        let logger = SuggestionDebugLogger(artifactStore: artifactStore)
        let preview = CompletionPlaygroundService().preview(
            prefix: "secret prefix ",
            suffix: " secret suffix",
            settings: CompletionBackendSettings(remoteModel: "test-model")
        )
        let result = CompletionPlaygroundResult(
            preview: preview,
            rawOutput: "secret raw output",
            normalizedOutput: "secret normalized output",
            latencyMs: 9
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        logger.recordPlaygroundResult(result, options: .normal)

        XCTAssertEqual(artifactStore.artifactCount(), 0)

        logger.recordPlaygroundResult(result, options: AutoCompDebugOptions(localDebugOptIn: true))

        let urls = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(urls.count, 1)
        let body = try String(contentsOf: urls[0], encoding: .utf8)
        XCTAssertTrue(body.contains("Prompt:"))
        XCTAssertTrue(body.contains("secret prefix"))
        XCTAssertTrue(body.contains("secret raw output"))
    }

    private func temporaryDirectory() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("autocomp-debug-\(UUID().uuidString)", isDirectory: true)
    }
}
