@testable import AutoCompApp
import Foundation
import XCTest

final class CIHeadlessScriptTests: XCTestCase {
    func testScriptDocumentsHeadlessBoundariesAndExitCategories() throws {
        let script = try String(
            contentsOf: try packageRoot().appendingPathComponent("script/ci_headless.sh"),
            encoding: .utf8
        )

        for requiredText in [
            "swift package dump-package",
            "build_without_llama.sh",
            "build_with_llama.sh",
            "swift test",
            "release_build.sh",
            "AUTOCOMP_CI_RUN_LLAMA_MATRIX",
            "Accessibility, AppleEvents, TextEdit, System Events, or real host apps",
            "EXIT_BUILD_FAILURE=10",
            "EXIT_TEST_FAILURE=11",
            "EXIT_RELEASE_DRY_RUN_FAILURE=12",
            "EXIT_MISSING_TARGET=20",
            "EXIT_ENVIRONMENT_SKIP=30"
        ] {
            XCTAssertTrue(script.contains(requiredText), "Missing CI contract text: \(requiredText)")
        }
    }

    func testDiscoveryOnlyReportsRequiredTargetsAndOptionalRuntimeSkip() throws {
        let packageDump = try writePackageDump(testTargets: [
            "AutoCompAppTests",
            "AutoCompCoreTests"
        ])
        defer {
            try? FileManager.default.removeItem(at: packageDump)
        }

        let result = try runCIHeadless(
            arguments: ["--discovery-only"],
            environment: ["AUTOCOMP_CI_PACKAGE_DUMP_FILE": packageDump.path]
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("AutoCompAppTests"))
        XCTAssertTrue(result.output.contains("AutoCompCoreTests"))
        XCTAssertTrue(result.output.contains("environment skip: AutoCompLlamaRuntimeTests"))
        XCTAssertTrue(result.output.contains("discovery-only complete"))
    }

    func testDiscoveryOnlyFailsClearlyForMissingExpectedTarget() throws {
        let packageDump = try writePackageDump(testTargets: [
            "AutoCompCoreTests"
        ])
        defer {
            try? FileManager.default.removeItem(at: packageDump)
        }

        let result = try runCIHeadless(
            arguments: ["--discovery-only"],
            environment: ["AUTOCOMP_CI_PACKAGE_DUMP_FILE": packageDump.path]
        )

        XCTAssertEqual(result.status, 20, result.output)
        XCTAssertTrue(result.output.contains("Missing required test target(s): AutoCompAppTests"))
        XCTAssertTrue(result.output.contains("Discovered test targets:"))
    }

    private func writePackageDump(testTargets: [String]) throws -> URL {
        let targets = testTargets
            .map { #"{"name":"\#($0)","type":"test"}"# }
            .joined(separator: ",")
        let json = #"{"targets":[\#(targets)]}"#
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("autocomp-package-dump-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func runCIHeadless(
        arguments: [String],
        environment: [String: String]
    ) throws -> (status: Int32, output: String) {
        let root = try packageRoot()
        let process = Process()
        process.currentDirectoryURL = root
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["script/ci_headless.sh"] + arguments
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
