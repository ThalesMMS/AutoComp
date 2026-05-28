@testable import AutoCompApp
import XCTest

final class OptionalUIScriptTests: XCTestCase {
    func testScriptDocumentsPermissionAwareContract() throws {
        let script = try String(
            contentsOf: try packageRoot().appendingPathComponent("script/ci_ui_optional.sh"),
            encoding: .utf8
        )

        for requiredText in [
            "--allow-skip",
            "ui_smoke_test.sh",
            "ui_inline_preview_smoke_test.sh",
            "ui_playground_smoke_test.sh",
            "AXIsProcessTrusted",
            "CGPreflightListenEventAccess",
            "System Events",
            "UI optional report:",
            "UI optional results:",
            "checks are skipped for missing"
        ] {
            XCTAssertTrue(script.contains(requiredText), "Missing optional UI script contract text: \(requiredText)")
        }
    }

    func testAllowSkipWritesStructuredReportForMissingPrerequisites() throws {
        let root = try packageRoot()
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("autocomp-ui-optional-skip-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: outputDirectory)
        }

        let result = try runOptionalUIScript(
            root: root,
            arguments: ["--allow-skip", "--output-dir", outputDirectory.path],
            environment: missingPrerequisiteEnvironment()
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("UI optional status: SKIPPED"))

        let report = try onlyMarkdownReport(in: outputDirectory)
        let reportText = try String(contentsOf: report, encoding: .utf8)
        XCTAssertTrue(reportText.contains("Detected Prerequisites"))
        XCTAssertTrue(reportText.contains("| Accessibility | missing | AXIsProcessTrusted |"))
        XCTAssertTrue(reportText.contains("| ui-settings-backend | SKIPPED | `n/a` |"))
        XCTAssertTrue(reportText.contains("backend=missing"))

        let results = try String(
            contentsOf: outputDirectory.appendingPathComponent("ci-ui-optional-results.tsv"),
            encoding: .utf8
        )
        XCTAssertTrue(results.contains("prerequisite\tAccessibility\tmissing"))
        XCTAssertTrue(results.contains("check\tui-inline-preview\tSKIPPED"))
    }

    func testStrictModeFailsClearlyForMissingPrerequisites() throws {
        let root = try packageRoot()
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("autocomp-ui-optional-strict-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: outputDirectory)
        }

        let result = try runOptionalUIScript(
            root: root,
            arguments: ["--output-dir", outputDirectory.path],
            environment: missingPrerequisiteEnvironment()
        )

        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertTrue(result.output.contains("missing required UI prerequisites"))
        XCTAssertTrue(result.output.contains("UI optional status: FAILED"))
        _ = try onlyMarkdownReport(in: outputDirectory)
    }

    func testPreparedEnvironmentRunsAllUISmokeScripts() throws {
        let root = try packageRoot()
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("autocomp-ui-optional-pass-\(UUID().uuidString)")
        let fakeScriptDirectory = outputDirectory.appendingPathComponent("fake-script")
        let markerDirectory = outputDirectory.appendingPathComponent("markers")
        defer {
            try? FileManager.default.removeItem(at: outputDirectory)
        }
        try FileManager.default.createDirectory(at: fakeScriptDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: markerDirectory, withIntermediateDirectories: true)

        for scriptName in [
            "ui_smoke_test.sh",
            "ui_inline_preview_smoke_test.sh",
            "ui_playground_smoke_test.sh"
        ] {
            let script = fakeScriptDirectory.appendingPathComponent(scriptName)
            try """
            #!/usr/bin/env bash
            set -euo pipefail
            printf "%s\\n" "$0 $*" > "\(markerDirectory.appendingPathComponent(scriptName).path)"
            """.write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        }

        var environment = preparedPrerequisiteEnvironment()
        environment["AUTOCOMP_CI_UI_SCRIPT_DIR"] = fakeScriptDirectory.path

        let result = try runOptionalUIScript(
            root: root,
            arguments: ["--output-dir", outputDirectory.path, "--safe-overlay-mode"],
            environment: environment
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("UI optional status: PASSED"))
        for scriptName in [
            "ui_smoke_test.sh",
            "ui_inline_preview_smoke_test.sh",
            "ui_playground_smoke_test.sh"
        ] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: markerDirectory.appendingPathComponent(scriptName).path))
        }

        let results = try String(
            contentsOf: outputDirectory.appendingPathComponent("ci-ui-optional-results.tsv"),
            encoding: .utf8
        )
        XCTAssertTrue(results.contains("check\tui-settings-backend\tPASSED"))
        XCTAssertTrue(results.contains("check\tui-inline-preview\tPASSED"))
        XCTAssertTrue(results.contains("check\tui-playground\tPASSED"))
        XCTAssertFalse(results.contains("\tSKIPPED\t"))
    }

    private func missingPrerequisiteEnvironment() -> [String: String] {
        [
            "AUTOCOMP_CI_UI_ACCESSIBILITY_STATUS": "missing",
            "AUTOCOMP_CI_UI_INPUT_MONITORING_STATUS": "missing",
            "AUTOCOMP_CI_UI_APPLE_EVENTS_STATUS": "missing",
            "AUTOCOMP_CI_UI_BACKEND_STATUS": "missing"
        ]
    }

    private func preparedPrerequisiteEnvironment() -> [String: String] {
        [
            "AUTOCOMP_CI_UI_ACCESSIBILITY_STATUS": "available",
            "AUTOCOMP_CI_UI_INPUT_MONITORING_STATUS": "available",
            "AUTOCOMP_CI_UI_APPLE_EVENTS_STATUS": "available",
            "AUTOCOMP_CI_UI_BACKEND_STATUS": "available"
        ]
    }

    private func runOptionalUIScript(
        root: URL,
        arguments: [String],
        environment: [String: String]
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.currentDirectoryURL = root
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["script/ci_ui_optional.sh"] + arguments
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        return (
            process.terminationStatus,
            String(data: data, encoding: .utf8) ?? ""
        )
    }

    private func onlyMarkdownReport(in directory: URL) throws -> URL {
        let reports = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "md" }
        XCTAssertEqual(reports.count, 1)
        return try XCTUnwrap(reports.first)
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
