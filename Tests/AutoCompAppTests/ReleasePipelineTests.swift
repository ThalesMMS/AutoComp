@testable import AutoCompApp
import XCTest

final class ReleasePipelineTests: XCTestCase {
    func testReleaseDocumentationCoversRequiredDistributionStages() throws {
        let document = try String(
            contentsOf: try packageRoot().appendingPathComponent("Docs/ReleasePipeline.md"),
            encoding: .utf8
        )

        for requiredText in [
            "Sparkle",
            "Developer ID",
            "notarytool",
            "DMG",
            "appcast",
            "AUTOCOMP_RELEASE_SIGNING_IDENTITY",
            "AUTOCOMP_NOTARY_PROFILE",
            "AUTOCOMP_SPARKLE_FEED_URL",
            "AUTOCOMP_SPARKLE_PUBLIC_KEY",
            "AUTOCOMP_SPARKLE_PRIVATE_KEY_FILE",
            "./script/release_build.sh --beta-gate",
            "./script/release_build.sh --dry-run",
            "beta-gate-results.tsv",
            "release-checklist.md",
            "./script/ci_ui_optional.sh --allow-skip",
            "optional UI report path",
            "multi-suggestion popup",
            "skip_reason=",
            "--include-llama-runtime",
            "Check for Updates..."
        ] {
            XCTAssertTrue(document.contains(requiredText), "Missing release documentation text: \(requiredText)")
        }
    }

    func testReleaseScriptsStaySeparateFromDevelopmentLauncher() throws {
        let root = try packageRoot()
        let localLauncher = try String(
            contentsOf: root.appendingPathComponent("script/build_and_run.sh"),
            encoding: .utf8
        )
        let releaseBuild = try String(
            contentsOf: root.appendingPathComponent("script/release_build.sh"),
            encoding: .utf8
        )

        XCTAssertFalse(localLauncher.contains("release_build.sh"))
        XCTAssertFalse(localLauncher.contains("notarytool"))
        XCTAssertFalse(localLauncher.contains("release_appcast.py"))
        XCTAssertTrue(releaseBuild.contains("swift build -c release --product"))
        XCTAssertTrue(releaseBuild.contains("copy_sparkle_framework"))
        XCTAssertTrue(releaseBuild.contains("Sparkle-for-Swift-Package-Manager.zip"))
        XCTAssertTrue(releaseBuild.contains("SPARKLE_ARCHIVE_CHECKSUM"))
        XCTAssertTrue(releaseBuild.contains("SUFeedURL"))
        XCTAssertTrue(releaseBuild.contains("SUPublicEDKey"))
        XCTAssertTrue(releaseBuild.contains("release_dmg.sh"))
        XCTAssertTrue(releaseBuild.contains("release_appcast.py"))
        XCTAssertTrue(releaseBuild.contains("release_checklist.py"))
        XCTAssertTrue(releaseBuild.contains("release-checklist.md"))
        XCTAssertTrue(releaseBuild.contains("assert_beta_gate_allows_release"))
        XCTAssertTrue(releaseBuild.contains("preserve_beta_gate_artifacts"))
        XCTAssertTrue(releaseBuild.contains("--dry-run"))
        XCTAssertTrue(releaseBuild.contains("--beta-gate"))
        XCTAssertTrue(releaseBuild.contains("--include-llama-runtime"))
    }

    func testReleaseBuildBundlesOptionalLlamaRuntimeWhenRequested() throws {
        let releaseBuild = try String(
            contentsOf: try packageRoot().appendingPathComponent("script/release_build.sh"),
            encoding: .utf8
        )

        for requiredText in [
            "INCLUDE_LLAMA_RUNTIME",
            "check_llama_pkg_config.sh",
            "run_release_swift",
            "bundle_llama_runtime_dylibs",
            "copy_llama_dylib_closure",
            "install_name_tool -add_rpath",
            "install_name_tool -change",
            "otool -L",
            "libllama",
            "libggml",
            "Bundled llama runtime link still points outside the app bundle",
            "codesign --force --options runtime --sign \"$SIGNING_IDENTITY\" \"$bundled_dylib\"",
            "spctl -a -t exec -vv"
        ] {
            XCTAssertTrue(releaseBuild.contains(requiredText), "Missing llama release contract text: \(requiredText)")
        }
    }

    func testBetaGateScriptCoversP0RowsAndStructuredSkips() throws {
        let root = try packageRoot()
        let releaseBuild = try String(
            contentsOf: root.appendingPathComponent("script/release_build.sh"),
            encoding: .utf8
        )
        let betaGate = try String(
            contentsOf: root.appendingPathComponent("script/beta_gate.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(releaseBuild.contains("script/beta_gate.sh"))
        for requiredText in [
            "P0-#99-headless-ci",
            "P0-#100-llama-build",
            "P0-#106-ui-smoke",
            "P0-#102-privacy-redaction",
            "P0-#103-delete-all-privacy-data",
            "P0-#105-secure-field",
            "P0-#101-startup-side-effects",
            "P0-#106-hardcoded-secrets",
            "P0-#106-prompt-preview-opt-in",
            "beta-gate-results.tsv",
            "REQUIRED",
            "CONDITIONAL",
            "SKIPPED",
            "skip_reason=",
            "--skip-ui-smoke",
            "--skip-llama-build",
            "ci_headless.sh",
            "ci_ui_optional.sh"
        ] {
            XCTAssertTrue(betaGate.contains(requiredText), "Missing beta gate contract text: \(requiredText)")
        }
    }

    func testReleaseHelpersOwnDmgAndAppcastBoundaries() throws {
        let root = try packageRoot()
        let dmgScript = try String(
            contentsOf: root.appendingPathComponent("script/release_dmg.sh"),
            encoding: .utf8
        )
        let appcastScript = try String(
            contentsOf: root.appendingPathComponent("script/release_appcast.py"),
            encoding: .utf8
        )
        let checklistScript = try String(
            contentsOf: root.appendingPathComponent("script/release_checklist.py"),
            encoding: .utf8
        )

        XCTAssertTrue(dmgScript.contains("hdiutil create"))
        XCTAssertTrue(dmgScript.contains("/Applications"))
        XCTAssertTrue(appcastScript.contains("sparkle:edSignature"))
        XCTAssertTrue(appcastScript.contains("--dry-run"))
        for requiredText in [
            "P0-#99-headless-ci",
            "P0-#106-ui-smoke",
            "QA matrix/report",
            "UI optional report",
            "Multi-suggestion popup",
            "DISABLED_BY_DEFAULT",
            "Sparkle Metadata",
            "Local llama runtime bundling",
            "Private key: not recorded",
            "Release Blockers"
        ] {
            XCTAssertTrue(checklistScript.contains(requiredText), "Missing checklist contract text: \(requiredText)")
        }
    }

    func testAppLoadsSparkleAndExposesUpdateMenuItem() throws {
        let root = try packageRoot()
        let package = try String(
            contentsOf: root.appendingPathComponent("Package.swift"),
            encoding: .utf8
        )
        let serviceSource = try String(
            contentsOf: root.appendingPathComponent("Sources/AutoCompApp/Services/SparkleUpdaterService.swift"),
            encoding: .utf8
        )
        let menuSource = try String(
            contentsOf: root.appendingPathComponent("Sources/AutoCompApp/Views/MenuBarContentView.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(package.contains("sparkle-project/Sparkle"))
        XCTAssertTrue(serviceSource.contains("Sparkle.framework"))
        XCTAssertTrue(serviceSource.contains("SPUStandardUpdaterController"))
        XCTAssertTrue(serviceSource.contains("checkForUpdates:"))
        XCTAssertTrue(menuSource.contains("Check for Updates..."))
    }

    func testReleaseDryRunGeneratesPlaceholderAppcast() throws {
        let root = try packageRoot()
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("autocomp-release-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: outputDirectory)
        }

        let process = Process()
        process.currentDirectoryURL = root
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "script/release_build.sh",
            "--dry-run",
            "--version",
            "0.0.0",
            "--build",
            "0",
            "--download-url",
            "https://example.invalid/AutoComp.dmg",
            "--release-notes-url",
            "https://example.invalid/releases/v0.0.0",
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

        let appcast = try String(
            contentsOf: outputDirectory.appendingPathComponent("appcast.xml"),
            encoding: .utf8
        )
        XCTAssertTrue(appcast.contains("sparkle:edSignature=\"dry-run-ed25519-signature\""))
        XCTAssertTrue(appcast.contains("length=\"0\""))

        let checklist = try String(
            contentsOf: outputDirectory.appendingPathComponent("release-checklist.md"),
            encoding: .utf8
        )
        XCTAssertTrue(checklist.contains("Version: 0.0.0"))
        XCTAssertTrue(checklist.contains("Build: 0"))
        XCTAssertTrue(checklist.contains("#106 beta gate"))
        XCTAssertTrue(checklist.contains("Swift test/headless gate"))
        XCTAssertTrue(checklist.contains("UI smoke"))
        XCTAssertTrue(checklist.contains("QA matrix/report"))
        XCTAssertTrue(checklist.contains("Multi-suggestion popup"))
        XCTAssertTrue(checklist.contains("DISABLED_BY_DEFAULT"))
        XCTAssertTrue(checklist.contains("Codesign"))
        XCTAssertTrue(checklist.contains("Notarization"))
        XCTAssertTrue(checklist.contains("Stapling"))
        XCTAssertTrue(checklist.contains("Appcast"))
        XCTAssertTrue(checklist.contains("Sparkle Metadata"))
        XCTAssertTrue(checklist.contains("Appcast Ed25519 signature: `dry-run-ed25519-signature`"))
        XCTAssertTrue(checklist.contains("Local llama runtime bundled: no"))
    }

    func testReleaseChecklistLinksOptionalUIReportFromBetaGateLog() throws {
        let root = try packageRoot()
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("autocomp-release-ui-report-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: outputDirectory)
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let uiReport = outputDirectory.appendingPathComponent("ci-ui-optional-report.md")
        try "# Optional UI Report\n".write(to: uiReport, atomically: true, encoding: .utf8)
        let uiLog = outputDirectory.appendingPathComponent("ui-optional.log")
        try "UI optional report: \(uiReport.path)\n".write(to: uiLog, atomically: true, encoding: .utf8)
        let betaGateResults = outputDirectory.appendingPathComponent("beta-gate-results.tsv")
        try """
        id\tissue\trequirement\tstatus\tevidence\tnote
        P0-#106-ui-smoke\t#106,#107\tCONDITIONAL\tSKIPPED\t\(uiLog.path)\tskip_reason=ui-inline-preview=Accessibility=missing
        """.write(to: betaGateResults, atomically: true, encoding: .utf8)

        let process = Process()
        process.currentDirectoryURL = root
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "script/release_checklist.py",
            "--output",
            outputDirectory.appendingPathComponent("release-checklist.md").path,
            "--output-dir",
            outputDirectory.path,
            "--version",
            "1.2.3",
            "--build",
            "123",
            "--mode",
            "dry-run",
            "--beta-gate-results",
            betaGateResults.path,
            "--app-bundle",
            outputDirectory.appendingPathComponent("AutoComp.app").path,
            "--dmg",
            outputDirectory.appendingPathComponent("AutoComp.dmg").path,
            "--appcast",
            outputDirectory.appendingPathComponent("appcast.xml").path,
            "--download-url",
            "https://example.invalid/AutoComp.dmg",
            "--release-notes-url",
            "https://example.invalid/releases/v1.2.3",
            "--sparkle-public-key",
            "public-key",
            "--frameworks-dir",
            outputDirectory.appendingPathComponent("AutoComp.app/Contents/Frameworks").path
        ]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let commandOutput = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, commandOutput)

        let checklist = try String(
            contentsOf: outputDirectory.appendingPathComponent("release-checklist.md"),
            encoding: .utf8
        )
        XCTAssertTrue(checklist.contains(uiReport.path))
        XCTAssertTrue(checklist.contains("PASSED_WITH_SKIPS"))
    }

    func testReleaseChecklistBlocksFailedGateResultsWithoutSecrets() throws {
        let root = try packageRoot()
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("autocomp-release-checklist-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: outputDirectory)
        }
        try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)

        let betaGateResults = outputDirectory.appendingPathComponent("beta-gate-results.tsv")
        try """
        id\tissue\trequirement\tstatus\tevidence\tnote
        P0-#99-headless-ci\t#99,#106\tREQUIRED\tFAILED\t/tmp/headless.log\tHeadless CI gate failed
        """.write(to: betaGateResults, atomically: true, encoding: .utf8)

        let process = Process()
        process.currentDirectoryURL = root
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [
            "script/release_checklist.py",
            "--output",
            outputDirectory.appendingPathComponent("release-checklist.md").path,
            "--output-dir",
            outputDirectory.path,
            "--version",
            "1.2.3",
            "--build",
            "123",
            "--mode",
            "release",
            "--beta-gate-results",
            betaGateResults.path,
            "--app-bundle",
            outputDirectory.appendingPathComponent("AutoComp.app").path,
            "--dmg",
            outputDirectory.appendingPathComponent("AutoComp.dmg").path,
            "--appcast",
            outputDirectory.appendingPathComponent("appcast.xml").path,
            "--download-url",
            "https://example.invalid/AutoComp.dmg",
            "--release-notes-url",
            "https://example.invalid/releases/v1.2.3",
            "--sparkle-public-key",
            "public-key",
            "--skip-notarize",
            "--skip-appcast",
            "--frameworks-dir",
            outputDirectory.appendingPathComponent("AutoComp.app/Contents/Frameworks").path,
            "--enforce-blockers"
        ]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        XCTAssertNotEqual(process.terminationStatus, 0)
        let checklist = try String(
            contentsOf: outputDirectory.appendingPathComponent("release-checklist.md"),
            encoding: .utf8
        )
        XCTAssertTrue(checklist.contains("Beta gate P0-#99-headless-ci failed"))
        XCTAssertTrue(checklist.contains("Public key: `public-key`"))
        XCTAssertTrue(checklist.contains("Private key: not recorded"))
    }

    func testReleaseDryRunDocumentsOptionalLlamaBundlingPlan() throws {
        let root = try packageRoot()
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("autocomp-release-llama-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: outputDirectory)
        }

        let process = Process()
        process.currentDirectoryURL = root
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "script/release_build.sh",
            "--dry-run",
            "--include-llama-runtime",
            "--version",
            "0.0.0",
            "--build",
            "0",
            "--download-url",
            "https://example.invalid/AutoComp.dmg",
            "--release-notes-url",
            "https://example.invalid/releases/v0.0.0",
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
        XCTAssertTrue(commandOutput.contains("copy llama/ggml dylibs"))
        XCTAssertTrue(commandOutput.contains("rewrite llama/ggml install names and rpaths"))
        XCTAssertTrue(commandOutput.contains("verify otool links for bundled llama/ggml dylibs"))
        XCTAssertTrue(commandOutput.contains("lib{llama,ggml}*.dylib"))
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
