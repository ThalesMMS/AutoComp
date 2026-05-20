@testable import AutoCompApp
import XCTest

final class BuildScriptInfoPlistTests: XCTestCase {
    func testPackageDeclaresMacOS14Baseline() throws {
        let manifestURL = try packageRoot().appendingPathComponent("Package.swift")
        let manifest = try String(contentsOf: manifestURL, encoding: .utf8)

        XCTAssertTrue(manifest.contains("// swift-tools-version: 6.2"))
        XCTAssertTrue(manifest.contains(".macOS(.v14)"))
    }

    func testStagedBundleDeclaresMacOS14MinimumSystemVersion() throws {
        let scriptURL = try packageRoot().appendingPathComponent("script/build_and_run.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("MIN_SYSTEM_VERSION=\"14.0\""))
        XCTAssertTrue(script.contains("<key>LSMinimumSystemVersion</key>"))
        XCTAssertTrue(script.contains("<string>$MIN_SYSTEM_VERSION</string>"))
    }

    func testStagedBundleDeclaresLocalNetworkUsage() throws {
        let scriptURL = try packageRoot().appendingPathComponent("script/build_and_run.sh")
        let script = try String(contentsOf: scriptURL, encoding: .utf8)

        XCTAssertTrue(script.contains("<key>NSLocalNetworkUsageDescription</key>"))
        XCTAssertTrue(script.contains("configured autocomplete backend on the local network"))
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
