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
        XCTAssertTrue(package.contains("AUTOCOMP_ENABLE_CONSTRAINED_LOCAL_COMPLETION"))
        XCTAssertTrue(package.contains("AUTOCOMP_CONSTRAINED_LOCAL_COMPLETION"))
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
        XCTAssertTrue(environmentSource.contains("#if AUTOCOMP_CONSTRAINED_LOCAL_COMPLETION"))
        XCTAssertTrue(environmentSource.contains("ConstrainedLocalCompletionFeature.isEnabled()"))
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
        XCTAssertTrue(harness.contains("CompletionBackendDefaults.localMaxRAMBytes"))
        XCTAssertFalse(harness.contains("6_442_450_944"))
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
        XCTAssertTrue(bridge.contains("incremental_text"))
        XCTAssertTrue(bridge.contains("autocomp_llama_find_stop_sequence_offset_in_tail"))
        XCTAssertTrue(bridge.contains("break;"))
        XCTAssertTrue(runtime.contains("request.stopSequences"))
        XCTAssertTrue(runtime.contains("withCStringArray(stopSequences)"))
    }

    func testLlamaBridgeSamplerAcceptAndStopScanningStayLinear() throws {
        let bridge = try String(
            contentsOf: try packageRoot().appendingPathComponent("Sources/CLlamaBridge/CLlamaBridge.cpp"),
            encoding: .utf8
        )
        let loopStart = try XCTUnwrap(bridge.range(of: "for (int32_t i = 0; i < max_tokens; i++)"))
        let loopEnd = try XCTUnwrap(
            bridge.range(
                of: "if (generated_count == 0)",
                range: loopStart.upperBound..<bridge.endIndex
            )
        )
        let generationLoop = String(bridge[loopStart.lowerBound..<loopEnd.lowerBound])

        XCTAssertTrue(bridge.contains("llama_sampler_sample already accepts the sampled token"))
        XCTAssertFalse(generationLoop.contains("llama_sampler_accept(sampler, token);"))
        XCTAssertTrue(bridge.contains("autocomp_llama_append_token_text"))
        XCTAssertFalse(generationLoop.contains("autocomp_llama_detokenize_to_string(vocab, generated_tokens, generated_count, error)"))
        XCTAssertTrue(bridge.contains("autocomp_llama_find_stop_sequence_offset_in_tail"))
        XCTAssertTrue(generationLoop.contains("previous_incremental_text_length"))
        XCTAssertTrue(generationLoop.contains("autocomp_llama_find_stop_sequence_offset_in_tail"))
    }

    func testLlamaRuntimeFreesGeneratedCStringBeforePostGenerationCancellationCheck() throws {
        let runtime = try String(
            contentsOf: try packageRoot().appendingPathComponent("Sources/AutoCompLlamaRuntime/LlamaCppRuntimeBackend.swift"),
            encoding: .utf8
        )
        let generatedGuard = try XCTUnwrap(runtime.range(of: "guard let generated else"))
        let postGeneratedRange = generatedGuard.upperBound..<runtime.endIndex
        let freeDefer = try XCTUnwrap(
            runtime.range(
                of: "defer { autocomp_llama_string_free(generated) }",
                range: postGeneratedRange
            )
        )
        let cancellationCheck = try XCTUnwrap(
            runtime.range(of: "try Task.checkCancellation()", range: postGeneratedRange)
        )

        let freeOffset = runtime.distance(from: runtime.startIndex, to: freeDefer.lowerBound)
        let cancellationOffset = runtime.distance(from: runtime.startIndex, to: cancellationCheck.lowerBound)
        XCTAssertLessThan(freeOffset, cancellationOffset)
    }

    func testLlamaGenerationAllocationFailuresUseDistinctErrorCodes() throws {
        let bridge = try String(
            contentsOf: try packageRoot().appendingPathComponent("Sources/CLlamaBridge/CLlamaBridge.cpp"),
            encoding: .utf8
        )

        XCTAssertTrue(bridge.contains("autocomp_llama_set_error(error, 16, \"Could not allocate generated tokens.\");"))
        XCTAssertTrue(bridge.contains("autocomp_llama_set_error(error, 27, \"Could not allocate generated text.\");"))
        XCTAssertFalse(bridge.contains("autocomp_llama_set_error(error, 16, \"Could not allocate generated text.\");"))
    }

    func testLlamaRuntimeUsesProcessLevelBackendLifecycle() throws {
        let runtime = try String(
            contentsOf: try packageRoot().appendingPathComponent("Sources/AutoCompLlamaRuntime/LlamaCppRuntimeBackend.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(runtime.contains("LlamaBackendGlobalLifecycle"))
        XCTAssertTrue(runtime.contains("backendLifecycle.retain()"))
        XCTAssertTrue(runtime.contains("backendLifecycle.release()"))
        XCTAssertFalse(runtime.contains("backendInitialized"))
    }

    func testLlamaDetokenizeReservesCStringTerminatorCapacity() throws {
        let bridge = try String(
            contentsOf: try packageRoot().appendingPathComponent("Sources/CLlamaBridge/CLlamaBridge.cpp"),
            encoding: .utf8
        )
        let functionStart = try XCTUnwrap(
            bridge.range(of: "static char *autocomp_llama_detokenize_to_string")
        )
        let functionEnd = try XCTUnwrap(
            bridge.range(
                of: "static int32_t autocomp_llama_find_stop_sequence_offset",
                range: functionStart.upperBound..<bridge.endIndex
            )
        )
        let function = String(bridge[functionStart.lowerBound..<functionEnd.lowerBound])

        let terminatorSafeMaxLengthCount = function.components(separatedBy: "text_capacity - 1").count - 1
        XCTAssertEqual(terminatorSafeMaxLengthCount, 2)
        XCTAssertFalse(function.contains("\n        text_capacity,\n        false,"))
    }

    func testConstrainedLocalFeatureFlagIsRuntimeOptIn() {
        XCTAssertFalse(ConstrainedLocalCompletionFeature.isEnabled(values: [:]))
        XCTAssertFalse(
            ConstrainedLocalCompletionFeature.isEnabled(values: [
                ConstrainedLocalCompletionFeature.environmentKey: "0"
            ])
        )
        XCTAssertTrue(
            ConstrainedLocalCompletionFeature.isEnabled(values: [
                ConstrainedLocalCompletionFeature.environmentKey: "1"
            ])
        )
    }

    func testMultiBranchDecoderRequiresIndependentRuntimeOptInAndDerivesProfilePath() {
        XCTAssertFalse(ConstrainedLocalCompletionFeature.isMultiBranchEnabled(values: [:]))
        XCTAssertTrue(ConstrainedLocalCompletionFeature.isMultiBranchEnabled(values: [
            ConstrainedLocalCompletionFeature.multiBranchEnvironmentKey: "yes"
        ]))
        XCTAssertEqual(
            ConstrainedLocalCompletionFeature.tokenProfilePath(modelPath: "/tmp/model.gguf", values: [:]),
            "/tmp/model.gguf.actkp"
        )
        XCTAssertEqual(
            ConstrainedLocalCompletionFeature.tokenProfilePath(
                modelPath: "/tmp/model.gguf",
                values: [ConstrainedLocalCompletionFeature.tokenProfilePathEnvironmentKey: "/tmp/custom.actkp"]
            ),
            "/tmp/custom.actkp"
        )
    }

}
