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
            "TextEdit inline preview",
            "Notes",
            "Mail",
            "Safari browser text field",
            "Chrome generic text field",
            "Google Docs",
            "Firefox",
            "Slack",
            "Discord or generic Electron app",
            "Code editors disabled by default"
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
        XCTAssertTrue(document.contains("./script/ui_smoke_test.sh"))
        XCTAssertTrue(document.contains("--skip-ui"))
        XCTAssertTrue(document.contains("--reason"))
        XCTAssertTrue(document.contains("dist/qa/"))
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
