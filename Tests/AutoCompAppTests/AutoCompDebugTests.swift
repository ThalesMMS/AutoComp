import ApplicationServices
import AppKit
import AutoCompCore
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

    func testAXCapabilitySnapshotContainsOnlyRedactedCapabilityMetadata() throws {
        let secretText = "secret field text prompt clipboard ocr selected value"
        let snapshot = AXCapabilitySnapshot.make(
            focusSnapshot: makeFocusSnapshot(secretText: secretText),
            geometry: makeGeometry(),
            captureSources: [.accessibility, .screenOCR],
            capabilityPresence: AXElementCapabilityPresence(
                hasAXValue: true,
                hasAXSelectedTextRange: true,
                hasAXBoundsForRange: false
            )
        )
        let body = try encodedString(snapshot)

        XCTAssertTrue(body.contains("com.example.Editor"))
        XCTAssertTrue(body.contains("example.com"))
        XCTAssertTrue(body.contains("AXTextArea"))
        XCTAssertTrue(body.contains("hasAXValue"))
        XCTAssertTrue(body.contains("screenOCR"))
        XCTAssertTrue(body.contains("directCaret"))
        XCTAssertTrue(body.contains("\"x\" : 10.12"))
        XCTAssertFalse(body.contains(secretText))
        XCTAssertFalse(body.contains("secret field"))
        XCTAssertFalse(body.contains("prompt clipboard"))
        XCTAssertFalse(body.contains("ocr selected"))
        XCTAssertFalse(body.contains("selected value"))
        XCTAssertFalse(body.contains("focused-secret-element"))
        XCTAssertFalse(body.contains("Example Secret App"))
    }

    func testAXCapabilitySnapshotRecorderRequiresOptInAndExportsWithDebugLogs() throws {
        let directory = temporaryDirectory()
        let exportRoot = temporaryDirectory()
        let store = DebugArtifactStore(directory: directory)
        var enabled = false
        let recorder = AXCapabilitySnapshotRecorder(
            artifactStore: store,
            isEnabled: { enabled },
            now: { Date(timeIntervalSince1970: 42) }
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: exportRoot)
        }

        recorder.record(
            focusSnapshot: makeFocusSnapshot(secretText: "secret field text"),
            geometry: makeGeometry(),
            captureSources: [.accessibility],
            capabilityPresence: AXElementCapabilityPresence(
                hasAXValue: true,
                hasAXSelectedTextRange: true,
                hasAXBoundsForRange: true
            )
        )

        XCTAssertEqual(store.artifactCount(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))

        enabled = true
        recorder.record(
            focusSnapshot: makeFocusSnapshot(secretText: "secret field text"),
            geometry: makeGeometry(),
            captureSources: [.accessibility],
            capabilityPresence: AXElementCapabilityPresence(
                hasAXValue: true,
                hasAXSelectedTextRange: true,
                hasAXBoundsForRange: true
            )
        )

        XCTAssertEqual(store.artifactCount(), 1)
        let artifact = try XCTUnwrap(FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).first)
        XCTAssertTrue(artifact.lastPathComponent.contains("ax-capability-snapshot"))
        XCTAssertTrue(artifact.lastPathComponent.hasSuffix(".json"))
        let artifactBody = try String(contentsOf: artifact, encoding: .utf8)
        XCTAssertTrue(artifactBody.contains("hasAXBoundsForRange"))
        XCTAssertFalse(artifactBody.contains("secret field text"))

        let exportURL = try store.exportDebugLogs(
            to: exportRoot,
            options: .normal,
            createdAt: Date(timeIntervalSince1970: 84)
        )
        let exportedArtifacts = try FileManager.default.contentsOfDirectory(
            at: exportURL.appendingPathComponent("DebugArtifacts", isDirectory: true),
            includingPropertiesForKeys: nil
        )
        XCTAssertEqual(exportedArtifacts.count, 1)
        XCTAssertTrue(exportedArtifacts[0].lastPathComponent.hasSuffix(".json"))

        try store.deleteAll()
        XCTAssertEqual(store.artifactCount(), 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testAXCapabilitySnapshotPromotesToDeterministicFixtureSeedWithoutContent() throws {
        let secretText = "secret prompt and selected text"
        let snapshot = AXCapabilitySnapshot.make(
            focusSnapshot: makeFocusSnapshot(secretText: secretText),
            geometry: makeGeometry(),
            captureSources: [.screenOCR, .accessibility],
            capabilityPresence: AXElementCapabilityPresence(
                hasAXValue: true,
                hasAXSelectedTextRange: true,
                hasAXBoundsForRange: true
            )
        )

        let seed = snapshot.fixtureSeed()
        XCTAssertEqual(seed, snapshot.fixtureSeed())
        XCTAssertTrue(seed.id.hasPrefix("ax-capability-com-example-editor-"))
        XCTAssertEqual(seed.textBeforeCursor, AXCapabilitySnapshotFixtureSeed.syntheticText)
        XCTAssertEqual(seed.captureSources, ["accessibility", "screenOCR"])

        let body = try encodedString(seed)
        XCTAssertTrue(body.contains(seed.id))
        XCTAssertTrue(body.contains("synthetic fixture prefix"))
        XCTAssertFalse(body.contains(secretText))
        XCTAssertFalse(body.contains("secret prompt"))
        XCTAssertFalse(body.contains("selected text"))
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

    private func makeFocusSnapshot(secretText: String) -> AXFocusSnapshot {
        AXFocusSnapshot(
            app: AppIdentity(
                bundleID: "com.example.Editor",
                displayName: "Example Secret App",
                processID: 42
            ),
            bundleID: "com.example.Editor",
            displayName: "Example Secret App",
            focusedElement: AXUIElementCreateSystemWide(),
            focusedElementID: "focused-secret-element",
            domain: "example.com",
            domainResolution: .known("example.com"),
            role: "AXTextArea",
            subrole: "AXDocument",
            isGoogleDocsElement: false,
            isCodexComposerElement: false,
            selectedRange: NSRange(location: 7, length: 6),
            fullText: secretText,
            textLength: (secretText as NSString).length,
            textBeforeCursor: "secret field prefix",
            textAfterCursor: "secret field suffix",
            selectedText: "secret selected text",
            fullTextWindow: "secret full text window"
        )
    }

    private func makeGeometry() -> AXTextGeometrySnapshot {
        AXTextGeometrySnapshot(
            focusedElementRect: CGRect(x: 1, y: 2, width: 300, height: 100),
            caretRect: CGRect(x: 10.123, y: 20.987, width: 1, height: 18),
            previousGlyphRect: CGRect(x: 8, y: 20, width: 9, height: 18),
            nextGlyphRect: nil,
            lineReferenceRect: CGRect(x: 8, y: 20, width: 9, height: 18),
            caretGeometryQuality: .directCaret,
            observedCharacterWidth: 9.123
        )
    }

    private func encodedString<T: Encodable>(_ value: T) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(value)
        return try XCTUnwrap(String(data: data, encoding: .utf8))
    }
}
