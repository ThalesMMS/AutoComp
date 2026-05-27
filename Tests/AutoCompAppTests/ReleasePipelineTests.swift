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
            "./script/release_build.sh --dry-run",
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
        XCTAssertTrue(releaseBuild.contains("--dry-run"))
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

        XCTAssertTrue(dmgScript.contains("hdiutil create"))
        XCTAssertTrue(dmgScript.contains("/Applications"))
        XCTAssertTrue(appcastScript.contains("sparkle:edSignature"))
        XCTAssertTrue(appcastScript.contains("--dry-run"))
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
