@testable import AutoCompApp
import Foundation
import XCTest

final class LlamaRuntimeBuildContractTests: XCTestCase {
    func testPackageManifestMakesLlamaRuntimeExplicitOptIn() throws {
        let package = try String(
            contentsOf: try packageRoot().appendingPathComponent("Package.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(package.contains("AUTOCOMP_ENABLE_LLAMA_RUNTIME"))
        XCTAssertTrue(package.contains("AUTOCOMP_LLAMA_CFLAGS"))
        XCTAssertTrue(package.contains("AUTOCOMP_LLAMA_LIBS"))
        XCTAssertTrue(package.contains("AUTOCOMP_LLAMA_RUNTIME"))
        XCTAssertTrue(package.contains("pkg-config"))
        XCTAssertTrue(package.contains("check_llama_pkg_config.sh"))
        XCTAssertFalse(package.contains("/opt/homebrew/include"))
        XCTAssertFalse(package.contains("/opt/homebrew/lib"))
        XCTAssertFalse(package.contains("fileExists(atPath:"))
    }

    func testAppRuntimeImportUsesManifestFlagInsteadOfStaleModuleCacheDiscovery() throws {
        let root = try packageRoot()
        let environmentSource = try String(
            contentsOf: root.appendingPathComponent("Sources/AutoCompApp/App/AutoCompAppEnvironment.swift"),
            encoding: .utf8
        )
        let settingsSource = try String(
            contentsOf: root.appendingPathComponent("Sources/AutoCompApp/Services/CompletionBackendConfigurationService.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(environmentSource.contains("#if AUTOCOMP_LLAMA_RUNTIME"))
        XCTAssertTrue(settingsSource.contains("#if AUTOCOMP_LLAMA_RUNTIME"))
        XCTAssertTrue(settingsSource.contains("runtimeSystemInfo()"))
        XCTAssertFalse(environmentSource.contains("canImport(AutoCompLlamaRuntime)"))
        XCTAssertFalse(settingsSource.contains("canImport(AutoCompLlamaRuntime)"))
    }

    func testReadmeAndLocalRuntimeDocDescribeSameOptInContract() throws {
        let root = try packageRoot()
        let readme = try String(
            contentsOf: root.appendingPathComponent("README.md"),
            encoding: .utf8
        )
        let localRuntimeDoc = try String(
            contentsOf: root.appendingPathComponent("Docs/LocalLlamaInProcessLinking.md"),
            encoding: .utf8
        )

        for requiredText in [
            "AUTOCOMP_ENABLE_LLAMA_RUNTIME=1",
            "AUTOCOMP_LLAMA_CFLAGS",
            "AUTOCOMP_LLAMA_LIBS",
            "./script/check_llama_pkg_config.sh"
        ] {
            XCTAssertTrue(readme.contains(requiredText), "README missing \(requiredText)")
            XCTAssertTrue(localRuntimeDoc.contains(requiredText), "Local runtime doc missing \(requiredText)")
        }
    }

    func testLlamaLinkValidationScriptSupportsPkgConfigAndExplicitFlags() throws {
        let script = try String(
            contentsOf: try packageRoot().appendingPathComponent("script/check_llama_pkg_config.sh"),
            encoding: .utf8
        )

        XCTAssertTrue(script.contains("pkg-config --exists llama"))
        XCTAssertTrue(script.contains("AUTOCOMP_LLAMA_CFLAGS"))
        XCTAssertTrue(script.contains("AUTOCOMP_LLAMA_LIBS"))
        XCTAssertTrue(script.contains("Set both AUTOCOMP_LLAMA_CFLAGS and AUTOCOMP_LLAMA_LIBS"))
        XCTAssertTrue(script.contains("llama_backend_init"))
        XCTAssertFalse(script.contains("/opt/homebrew"))
    }

    func testLlamaLoadHarnessSupportsMemoryLimitSimulation() throws {
        let root = try packageRoot()
        let harness = try String(
            contentsOf: root.appendingPathComponent("Sources/AutoCompLlamaLoadHarness/AutoCompLlamaLoadHarness.swift"),
            encoding: .utf8
        )
        let localRuntimeDoc = try String(
            contentsOf: root.appendingPathComponent("Docs/LocalLlamaInProcessLinking.md"),
            encoding: .utf8
        )

        XCTAssertTrue(harness.contains("--max-ram-bytes"))
        XCTAssertTrue(harness.contains("maxRAMBytes: options.maxRAMBytes"))
        XCTAssertTrue(localRuntimeDoc.contains("--max-ram-bytes BYTES"))
        XCTAssertTrue(localRuntimeDoc.contains("LocalLlamaError.allocationFailed"))
    }

    func testLlamaBridgeAppliesStopSequencesDuringGenerationLoop() throws {
        let root = try packageRoot()
        let header = try String(
            contentsOf: root.appendingPathComponent("Sources/CLlamaBridge/include/CLlamaBridge.h"),
            encoding: .utf8
        )
        let bridge = try String(
            contentsOf: root.appendingPathComponent("Sources/CLlamaBridge/CLlamaBridge.cpp"),
            encoding: .utf8
        )
        let runtime = try String(
            contentsOf: root.appendingPathComponent("Sources/AutoCompLlamaRuntime/LlamaCppRuntimeBackend.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(header.contains("stop_sequences"))
        XCTAssertTrue(header.contains("stop_sequence_count"))
        XCTAssertTrue(bridge.contains("autocomp_llama_find_stop_sequence_offset"))
        XCTAssertTrue(bridge.contains("partial_text"))
        XCTAssertTrue(bridge.contains("break;"))
        XCTAssertTrue(runtime.contains("request.stopSequences"))
        XCTAssertTrue(runtime.contains("withCStringArray(stopSequences)"))
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
