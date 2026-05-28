@testable import AutoCompApp
import Foundation
import XCTest

final class BuildMatrixScriptTests: XCTestCase {
    func testNoLlamaScriptForcesFallbackBuildContract() throws {
        let root = try packageRoot()
        let script = try String(
            contentsOf: root.appendingPathComponent("script/build_without_llama.sh"),
            encoding: .utf8
        )

        for requiredText in [
            "unset AUTOCOMP_ENABLE_LLAMA_RUNTIME",
            "unset AUTOCOMP_LLAMA_CFLAGS",
            "unset AUTOCOMP_LLAMA_LIBS",
            "AutoCompLlamaRuntime",
            "CompletionBackendConfigurationServiceTests/testInternalLocalSettingsLoadFromDefaults",
            "unavailable local-runtime fallback"
        ] {
            XCTAssertTrue(script.contains(requiredText), "Missing no-llama script contract: \(requiredText)")
        }
    }

    func testWithLlamaScriptBuildsRuntimeTargetsAndHandlesNoModel() throws {
        let root = try packageRoot()
        let script = try String(
            contentsOf: root.appendingPathComponent("script/build_with_llama.sh"),
            encoding: .utf8
        )

        for requiredText in [
            "check_llama_pkg_config.sh",
            "swift build --target CLlamaBridge",
            "swift build --target AutoCompLlamaRuntime",
            "swift build --product AutoCompLlamaLoadHarness",
            "AutoCompLlamaLoadHarness --status",
            "AUTOCOMP_LOCAL_MODEL_PATH",
            "no-model"
        ] {
            XCTAssertTrue(script.contains(requiredText), "Missing llama script contract: \(requiredText)")
        }
    }

    func testNoLlamaDiscoveryRejectsOptionalRuntimeTargets() throws {
        let packageDump = try writePackageDump(targets: [
            "AutoCompApp",
            "AutoCompCore",
            "AutoCompAppTests",
            "AutoCompCoreTests"
        ])
        defer {
            try? FileManager.default.removeItem(at: packageDump)
        }

        let result = try runScript(
            "script/build_without_llama.sh",
            arguments: ["--discovery-only"],
            environment: ["AUTOCOMP_BUILD_MATRIX_PACKAGE_DUMP_FILE": packageDump.path]
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("no-llama manifest excludes optional local runtime targets"))
        XCTAssertTrue(result.output.contains("discovery-only complete"))
    }

    func testWithLlamaDiscoveryRequiresRuntimeTargets() throws {
        let packageDump = try writePackageDump(targets: [
            "AutoCompApp",
            "AutoCompCore",
            "AutoCompAppTests",
            "AutoCompCoreTests",
            "CLlamaBridge",
            "AutoCompLlamaRuntime",
            "AutoCompLlamaLoadHarness",
            "AutoCompLlamaRuntimeTests"
        ])
        defer {
            try? FileManager.default.removeItem(at: packageDump)
        }

        let result = try runScript(
            "script/build_with_llama.sh",
            arguments: ["--discovery-only"],
            environment: ["AUTOCOMP_BUILD_MATRIX_PACKAGE_DUMP_FILE": packageDump.path]
        )

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("llama manifest includes optional runtime targets"))
        XCTAssertTrue(result.output.contains("discovery-only complete"))
    }

    func testWithLlamaDiscoveryFailsWhenRuntimeTargetIsMissing() throws {
        let packageDump = try writePackageDump(targets: [
            "AutoCompApp",
            "AutoCompCore",
            "AutoCompAppTests",
            "AutoCompCoreTests",
            "CLlamaBridge",
            "AutoCompLlamaLoadHarness",
            "AutoCompLlamaRuntimeTests"
        ])
        defer {
            try? FileManager.default.removeItem(at: packageDump)
        }

        let result = try runScript(
            "script/build_with_llama.sh",
            arguments: ["--discovery-only"],
            environment: ["AUTOCOMP_BUILD_MATRIX_PACKAGE_DUMP_FILE": packageDump.path]
        )

        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertTrue(result.output.contains("Missing required llama-runtime target: AutoCompLlamaRuntime"))
    }

    private func writePackageDump(targets: [String]) throws -> URL {
        let targetJSON = targets
            .map { #"{"name":"\#($0)","type":"regular"}"# }
            .joined(separator: ",")
        let json = #"{"targets":[\#(targetJSON)]}"#
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("autocomp-build-matrix-\(UUID().uuidString).json")
        try json.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func runScript(
        _ script: String,
        arguments: [String],
        environment: [String: String]
    ) throws -> (status: Int32, output: String) {
        let root = try packageRoot()
        let process = Process()
        process.currentDirectoryURL = root
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script] + arguments
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
