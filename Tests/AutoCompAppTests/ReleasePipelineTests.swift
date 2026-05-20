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
            "AUTOCOMP_SPARKLE_PRIVATE_KEY_FILE",
            "./script/release_build.sh --dry-run"
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
