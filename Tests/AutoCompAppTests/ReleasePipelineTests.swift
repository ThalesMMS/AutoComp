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

    func testReleaseDmgRefusesAppBundleWithEmbeddedLocalEnv() throws {
        let root = try packageRoot()
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("autocomp-release-dmg-env-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }

        let appBundle = tempRoot.appendingPathComponent("AutoComp.app", isDirectory: true)
        let resources = appBundle.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try "AUTOCOMP_REMOTE_API_KEY=secret\n".write(
            to: resources.appendingPathComponent("autocomp.env"),
            atomically: true,
            encoding: .utf8
        )

        let result = try runProcess(
            executable: "/bin/bash",
            arguments: [
                "script/release_dmg.sh",
                "--app-path",
                appBundle.path,
                "--output-path",
                tempRoot.appendingPathComponent("AutoComp.dmg").path
            ],
            currentDirectory: root
        )

        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertTrue(
            result.output.contains("Refusing to package app bundle containing embedded local environment file"),
            result.output
        )
        XCTAssertTrue(result.output.contains("AUTOCOMP_EMBED_ENV_LOCAL=0"), result.output)
    }

    func testReleaseBuildBetaGateHandlesEmptyForwardedArgsUnderStockBash() throws {
        let root = try packageRoot()
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("autocomp-beta-gate-empty-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        let scriptDirectory = tempRoot.appendingPathComponent("script")
        try FileManager.default.createDirectory(at: scriptDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(
            at: root.appendingPathComponent("script/release_build.sh"),
            to: scriptDirectory.appendingPathComponent("release_build.sh")
        )
        let betaGateStub = scriptDirectory.appendingPathComponent("beta_gate.sh")
        try """
        #!/bin/bash
        set -eu
        printf 'stub-beta-gate args=%s\\n' "$#"
        """.write(to: betaGateStub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: betaGateStub.path)

        let result = try runProcess(
            executable: "/bin/bash",
            arguments: ["script/release_build.sh", "--beta-gate"],
            currentDirectory: tempRoot
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("stub-beta-gate args=0"), result.output)
        XCTAssertFalse(result.output.contains("unbound variable"), result.output)
    }

    func testLlamaPkgConfigLinkCheckHandlesEmptyCFlagsUnderStockBash() throws {
        let root = try packageRoot()
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("autocomp-llama-pkg-config-empty-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        let binDirectory = tempRoot.appendingPathComponent("bin")
        let libDirectory = tempRoot.appendingPathComponent("lib")
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: libDirectory, withIntermediateDirectories: true)

        let pkgConfigStub = binDirectory.appendingPathComponent("pkg-config")
        try """
        #!/bin/bash
        set -eu
        case "$1" in
          --exists)
            exit 0
            ;;
          --cflags)
            exit 0
            ;;
          --libs)
            printf -- '-L%s -lllama\\n' "\(libDirectory.path)"
            exit 0
            ;;
        esac
        exit 2
        """.write(to: pkgConfigStub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: pkgConfigStub.path)

        let ccStub = binDirectory.appendingPathComponent("cc")
        try """
        #!/bin/bash
        set -eu
        output=""
        while [ "$#" -gt 0 ]; do
          if [ "$1" = "-o" ]; then
            shift
            output="$1"
          fi
          shift || true
        done
        if [ -z "$output" ]; then
          exit 2
        fi
        {
          echo '#!/bin/bash'
          echo 'exit 0'
        } >"$output"
        chmod +x "$output"
        """.write(to: ccStub, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: ccStub.path)

        let result = try runProcess(
            executable: "/bin/bash",
            arguments: ["script/check_llama_pkg_config.sh"],
            currentDirectory: root,
            environment: [
                "PATH": "\(binDirectory.path):/usr/bin:/bin:/usr/sbin:/sbin",
                "TMPDIR": FileManager.default.temporaryDirectory.path
            ]
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("llama.cpp link check passed using pkg-config"), result.output)
        XCTAssertFalse(result.output.contains("unbound variable"), result.output)
    }

    func testAppcastValidatorPreservesNoItemsExitCodeUnderStockBash() throws {
        let root = try packageRoot()
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("autocomp-appcast-empty-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        let appcast = tempRoot.appendingPathComponent("appcast.xml")
        try """
        <?xml version="1.0" encoding="utf-8"?>
        <rss version="2.0">
          <channel>
            <title>AutoComp appcast</title>
          </channel>
        </rss>
        """.write(to: appcast, atomically: true, encoding: .utf8)

        let result = try runProcess(
            executable: "/bin/bash",
            arguments: ["script/release_validate_appcast.sh", "--appcast", appcast.path],
            currentDirectory: root
        )

        XCTAssertEqual(result.status, 3, result.output)
        XCTAssertTrue(result.output.contains("No <item> entries found in appcast"), result.output)
        XCTAssertFalse(result.output.contains("unbound variable"), result.output)
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

    func testReleaseEvidenceForIssue185HasNoTBDAndRecordsExecutedArtifacts() throws {
        let evidence = try String(
            contentsOf: try packageRoot().appendingPathComponent("Docs/QA_EndToEnd_Release_Evidence.md"),
            encoding: .utf8
        )

        XCTAssertFalse(evidence.contains("_TBD_"))
        for requiredText in [
            "Issue #185",
            "dist/release/issue-185-dry-run.log",
            "dist/release/release-checklist.md",
            "dist/release/appcast.xml",
            "dist/appcast-test/issue-185/appcast.xml",
            "dist/appcast-test/issue-185/appcast_invalid_signature.xml",
            "dist/appcast-test/issue-185/appcast_missing_file.xml",
            "dist/appcast-test/issue-185/appcast_downgrade.xml",
            "Developer ID Application identity",
            "clean_install_verify.sh --dmg ./dist/release/AutoComp.dmg"
        ] {
            XCTAssertTrue(evidence.contains(requiredText), "Missing issue #185 evidence text: \(requiredText)")
        }
    }

    func testSparkleTestChannelGeneratesDowngradeAppcastAndLocalReleaseNotesURL() throws {
        let root = try packageRoot()
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("autocomp-appcast-test-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: outputDirectory)
        }
        let fixtureDirectory = outputDirectory.appendingPathComponent("fixture")
        let appcastDirectory = outputDirectory.appendingPathComponent("appcasts")
        try FileManager.default.createDirectory(at: fixtureDirectory, withIntermediateDirectories: true)

        let archive = fixtureDirectory.appendingPathComponent("AutoComp.dmg")
        try Data("placeholder archive".utf8).write(to: archive)

        let process = Process()
        process.currentDirectoryURL = root
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [
            "script/sparkle_test_channel_setup.sh",
            "--archive",
            archive.path,
            "--out-dir",
            appcastDirectory.path,
            "--channel",
            "beta",
            "--release-notes-url",
            "http://127.0.0.1:8765/release-notes.html"
        ]

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        let commandOutput = String(data: data, encoding: .utf8) ?? ""
        XCTAssertEqual(process.terminationStatus, 0, commandOutput)

        let valid = try String(
            contentsOf: appcastDirectory.appendingPathComponent("appcast.xml"),
            encoding: .utf8
        )
        let invalidSignature = try String(
            contentsOf: appcastDirectory.appendingPathComponent("appcast_invalid_signature.xml"),
            encoding: .utf8
        )
        let missingFile = try String(
            contentsOf: appcastDirectory.appendingPathComponent("appcast_missing_file.xml"),
            encoding: .utf8
        )
        let downgrade = try String(
            contentsOf: appcastDirectory.appendingPathComponent("appcast_downgrade.xml"),
            encoding: .utf8
        )

        XCTAssertTrue(valid.contains("http://127.0.0.1:8765/release-notes.html"))
        XCTAssertFalse(valid.contains("https://example.invalid/autocomp-test-channel"))
        XCTAssertTrue(valid.contains("<sparkle:channel>beta</sparkle:channel>"))
        XCTAssertFalse(valid.contains("sparkle:channel=\"beta\""))
        XCTAssertTrue(invalidSignature.contains("sparkle:edSignature=\"INVALID\""))
        XCTAssertTrue(missingFile.contains("missing-file-does-not-exist.dmg"))
        XCTAssertTrue(downgrade.contains("sparkle:shortVersionString=\"0.0.0\""))
        XCTAssertTrue(downgrade.contains("sparkle:version=\"0\""))
    }

    private func runProcess(
        executable: String,
        arguments: [String],
        currentDirectory: URL,
        environment: [String: String]? = nil
    ) throws -> (status: Int32, output: String) {
        let process = Process()
        process.currentDirectoryURL = currentDirectory
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment

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

}
