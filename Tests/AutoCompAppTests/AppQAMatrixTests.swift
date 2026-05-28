@testable import AutoCompApp
import XCTest

final class AppQAMatrixTests: XCTestCase {
    func testMatrixDocumentsRequiredAppsModesStepsAndEvidence() throws {
        let document = try String(
            contentsOf: try packageRoot().appendingPathComponent("Docs/AppQAMatrix.md"),
            encoding: .utf8
        )

        for requiredText in [
            "App or flow",
            "Expected mode",
            "Permissions needed",
            "Steps",
            "Expected result",
            "Evidence",
            "Settings > Model backend flow",
            "Install location and full local reset",
            "Settings > Apps activation modes",
            "Diagnostics",
            "`Compatibility`",
            "TextEdit inline preview",
            "TextEdit FIM controlled field",
            "Safe simple overlay mode",
            "AUTOCOMP_SAFE_OVERLAY_MODE=1",
            "--safe-overlay-mode",
            "safe-overlay-mode active",
            "Chrome textarea",
            "Notes",
            "Notes continuation and FIM",
            "Mail",
            "Mail manual-only FIM",
            "IME non-ASCII input source",
            "Unicode insertion with accents and emoji",
            "Clipboard fallback preserves rich content",
            "Multi-monitor and Retina overlay",
            "Safari browser text field",
            "Chrome generic text field",
            "Google Docs OCR and geometry",
            "Firefox",
            "Slack",
            "Discord or generic Electron app",
            "Telegram",
            "blocked-risky-host-app",
            "manual-only-waiting-for-trigger",
            "ime-composition-active",
            "input-source-non-ascii",
            "suffixLen=<nonzero>",
            "stale-visual-context",
            "source=visualContext-ocr",
            "source=screenOCR-geometry",
            "source=<accessibility|ocr-geometry|visual-ocr|keystroke-buffer>",
            "quality=<direct|glyph|line|element|ocr|unavailable>",
            "trust=<standard|low-trust>",
            "redacted settings export",
            "API keys, prompts, field text, OCR text, clipboard text",
            "visual-context status=screen-recording-off source=visualContext-ocr",
            "Code editors disabled by default",
            "Xcode",
            "JetBrains",
            "Terminals disabled by default",
            "WezTerm",
            "Alacritty",
            "PR changes focused-text capture",
            "reference the relevant row names"
        ] {
            XCTAssertTrue(document.contains(requiredText), "Missing QA matrix text: \(requiredText)")
        }
    }

    func testMatrixReferencesAutomatedSmokeCoverageAndSkipRecording() throws {
        let document = try String(
            contentsOf: try packageRoot().appendingPathComponent("Docs/AppQAMatrix.md"),
            encoding: .utf8
        )

        XCTAssertTrue(document.contains("./script/ui_inline_preview_smoke_test.sh"))
        XCTAssertTrue(document.contains("./script/ci_ui_optional.sh --allow-skip"))
        XCTAssertTrue(document.contains("ci-ui-optional-results.tsv"))
        XCTAssertTrue(document.contains("Accessibility, Input Monitoring, AppleEvents"))
        XCTAssertTrue(document.contains("./script/qa_real_app_matrix.sh --safe-overlay-mode"))
        XCTAssertTrue(document.contains("./script/ui_smoke_test.sh"))
        XCTAssertTrue(document.contains("./script/ui_playground_smoke_test.sh"))
        XCTAssertTrue(document.contains("multiSuggestion=disabled"))
        XCTAssertTrue(document.contains("AUTOCOMP_DEBUG_MULTI_SUGGESTION_ENABLED=1"))
        XCTAssertTrue(document.contains("./script/uninstall.sh --dry-run"))
        XCTAssertTrue(document.contains("--skip-ui"))
        XCTAssertTrue(document.contains("--reason"))
        XCTAssertTrue(document.contains("dist/qa/"))
        XCTAssertTrue(document.contains("redacted command logs"))
        XCTAssertTrue(document.contains("redacted prompt sizes and counts by default"))
        XCTAssertTrue(document.contains("Sensitive prompt content appears only after local debug opt-in"))
    }

    func testInlinePreviewSmokeCoversControlledFIMField() throws {
        let script = try String(
            contentsOf: try packageRoot().appendingPathComponent("script/ui_inline_preview_smoke_test.sh"),
            encoding: .utf8
        )
        let qaScript = try String(
            contentsOf: try packageRoot().appendingPathComponent("script/qa_real_app_matrix.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(script.contains("Controlled FIM case"))
        XCTAssertTrue(script.contains("--safe-overlay-mode"))
        XCTAssertTrue(script.contains("AUTOCOMP_SAFE_OVERLAY_MODE=1"))
        XCTAssertTrue(script.contains("safe-overlay-mode active feature=preview-tier"))
        XCTAssertTrue(script.contains("resolvedTier=visualInlineOverlay"))
        XCTAssertTrue(script.contains("tier=visualInlineOverlay .* panel="))
        XCTAssertTrue(script.contains("key code 48"))
        XCTAssertTrue(script.contains("acceptance accepted action=next-word"))
        XCTAssertTrue(script.contains("key code 49 using option down"))
        XCTAssertTrue(script.contains("suffixLen=[1-9][0-9]*"))
        XCTAssertTrue(script.contains("inline preview FIM smoke did not record a non-empty suffix completion"))
        XCTAssertTrue(qaScript.contains("--safe-overlay-mode"))
        XCTAssertTrue(qaScript.contains("ui inline preview smoke safe mode"))
    }

    func testQAScriptCanRecordSkippedUISmokeWithoutLaunchingApps() throws {
        let root = try packageRoot()
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("autocomp-qa-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: outputDirectory)
        }

        let process = Process()
        process.currentDirectoryURL = root
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "script/qa_real_app_matrix.sh",
            "--skip-swift-test",
            "--skip-ui",
            "--reason",
            "unit test skip",
            "--output-dir",
            outputDirectory.path
        ]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let commandOutput = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, commandOutput)

        let reports = try FileManager.default.contentsOfDirectory(
            at: outputDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "md" }
        XCTAssertEqual(reports.count, 1)

        let report = try String(contentsOf: reports[0], encoding: .utf8)
        XCTAssertTrue(report.contains("swift test | SKIPPED"))
        XCTAssertTrue(report.contains("ui inline preview smoke | SKIPPED"))
        XCTAssertTrue(report.contains("ui settings backend smoke | SKIPPED"))
        XCTAssertTrue(report.contains("unit test skip"))
        XCTAssertTrue(report.contains("Referenced command logs are redacted"))
        XCTAssertTrue(report.contains("Record non-content source, quality, and trust labels"))
        XCTAssertFalse(report.contains("typed text, OCR text, clipboard text, prompts, or completions.\nsecret"))
    }

    func testQAScriptRedactsSensitiveLogSections() throws {
        let root = try packageRoot()
        let logURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("autocomp-sensitive-\(UUID().uuidString).log")
        try """
        Text before cursor:
        secret typed text
        Completion:
        secret completion output
        FIM suffix injected:
        <visual_context>
        secret ocr text
        </visual_context>
        Clipboard context:
        secret clipboard text
        <|fim_middle|>
        safe diagnostic reason
        """.write(to: logURL, atomically: true, encoding: .utf8)
        defer {
            try? FileManager.default.removeItem(at: logURL)
        }

        let process = Process()
        process.currentDirectoryURL = root
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "script/qa_real_app_matrix.sh",
            "--redact-log",
            logURL.path
        ]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let commandOutput = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, commandOutput)

        let redacted = try String(contentsOf: logURL, encoding: .utf8)
        XCTAssertTrue(redacted.contains("[redacted]"))
        XCTAssertTrue(redacted.contains("[redacted visual context]"))
        XCTAssertTrue(redacted.contains("safe diagnostic reason"))
        XCTAssertFalse(redacted.contains("secret typed text"))
        XCTAssertFalse(redacted.contains("secret completion output"))
        XCTAssertFalse(redacted.contains("secret ocr text"))
        XCTAssertFalse(redacted.contains("secret clipboard text"))
    }

    private func packageRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url.deleteLastPathComponent()
        }

        throw XCTSkip("Unable to locate package root")
    }
}
