import AutoCompCore
@testable import AutoCompApp
import Foundation
import XCTest

final class ModelCompatibilityMatrixTests: XCTestCase {
    func testBundledMatrixCoversRequiredBackendClasses() {
        let matrix = ModelCompatibilityMatrix.bundled
        let classes = Set(matrix.rows.map(\.backendClass))

        XCTAssertEqual(classes, Set(ModelCompatibilityBackendClass.allCases))
        XCTAssertNotNil(matrix.rows.first { $0.id == "remote-openai-compatible-generic" })
        XCTAssertNotNil(matrix.rows.first { $0.id == "local-server-vllm-default" })
        XCTAssertNotNil(matrix.rows.first { $0.id == "apple-foundationmodels-system" })
        XCTAssertNotNil(matrix.rows.first { $0.id == "local-llama-qwen3-0_6b-q4" })
    }

    func testSettingsRecommendationDoesNotClaimFIMWithoutSupportedEvidence() {
        let localServerRecommendation = ModelCompatibilityMatrix.bundled.recommendation(
            for: CompletionBackendSettings(
                remoteBaseURL: "http://100.98.1.45:8000",
                remoteModel: "default"
            )
        )

        XCTAssertEqual(localServerRecommendation.row?.id, "local-server-vllm-default")
        XCTAssertTrue(localServerRecommendation.fimTitle.contains("not recommended without evidence"))
        XCTAssertTrue(localServerRecommendation.evidenceTitle.contains("vLLM 0.21.0"))

        let localModelRecommendation = ModelCompatibilityMatrix.bundled.recommendation(
            for: CompletionBackendSettings(
                engineKind: .localLlama,
                localModelPath: "/Models/Qwen3-0.6B-Q4_K_M.gguf"
            )
        )

        XCTAssertEqual(localModelRecommendation.row?.id, "local-llama-qwen3-0_6b-q4")
        XCTAssertTrue(localModelRecommendation.fimTitle.contains("not recommended without evidence"))
    }

    func testSupportedFIMRecommendationRequiresSupportedEvidence() {
        let supportedRow = ModelCompatibilityEvidenceRow(
            id: "test-supported-fim",
            backendClass: .remoteOpenAICompatible,
            backendModel: "Test model",
            modelMatch: nil,
            runtimeLifecycle: "Test lifecycle",
            fimSupport: .supported,
            multipleCompletions: .supported,
            averageLatencyMs: 12,
            latencySource: "Test redacted latency report",
            promptEchoTendency: "None observed in test metadata.",
            stopSequencesNeeded: "Default stops.",
            recommendedMaxTokens: 32,
            normalizerQuirks: "None.",
            evidenceDate: "2026-05-27",
            autoCompBuild: "test-build",
            backendVersion: "test-version",
            skippedOrUnknownReason: nil
        )
        let matrix = ModelCompatibilityMatrix(rows: [supportedRow])

        let recommendation = matrix.recommendation(
            for: CompletionBackendSettings(
                remoteBaseURL: "https://example.invalid",
                remoteModel: "test"
            )
        )

        XCTAssertEqual(recommendation.row?.id, "test-supported-fim")
        XCTAssertTrue(recommendation.fimTitle.contains("supported by matrix evidence"))
        XCTAssertFalse(recommendation.fimTitle.contains("not recommended"))
    }

    func testManualRowsCarryEvidenceMetadataAndSafeLatencyReasons() {
        for row in ModelCompatibilityMatrix.bundled.rows {
            XCTAssertFalse(row.evidenceDate.isEmpty, row.id)
            XCTAssertFalse(row.autoCompBuild.isEmpty, row.id)
            XCTAssertFalse(row.backendVersion.isEmpty, row.id)
            XCTAssertEqual(row.recommendedMaxTokens, 32, row.id)

            if row.averageLatencyMs == nil {
                XCTAssertFalse(row.skippedOrUnknownReason?.isEmpty ?? true, row.id)
                XCTAssertTrue(row.latencyTitle.contains("Unknown") || row.latencyTitle.contains("skipped"), row.id)
            }

            if row.fimSupport != .supported {
                XCTAssertTrue(row.fimRecommendationTitle.contains("not recommended"), row.id)
            }

            let publishedText = [
                row.backendModel,
                row.runtimeLifecycle,
                row.latencySource,
                row.promptEchoTendency,
                row.stopSequencesNeeded,
                row.normalizerQuirks,
                row.backendVersion,
                row.skippedOrUnknownReason ?? ""
            ].joined(separator: "\n")
            XCTAssertFalse(publishedText.contains("typed secret"), row.id)
            XCTAssertFalse(publishedText.contains("clipboard text"), row.id)
            XCTAssertFalse(publishedText.contains("OCR text"), row.id)
            XCTAssertFalse(publishedText.contains("com.apple.TextEdit"), row.id)
        }
    }

    func testDocumentationListsEveryBundledRowAndSafetyPolicy() throws {
        let document = try String(
            contentsOf: try packageRoot().appendingPathComponent("Docs/ModelCompatibilityMatrix.md"),
            encoding: .utf8
        )

        for row in ModelCompatibilityMatrix.bundled.rows {
            XCTAssertTrue(document.contains("`\(row.id)`"), "Document missing \(row.id)")
        }
        XCTAssertTrue(document.contains("FIM optimized behavior only when the matched matrix row"))
        XCTAssertTrue(document.contains("redacted latency report"))
        XCTAssertFalse(document.contains("typed secret"))
        XCTAssertFalse(document.contains("clipboard text"))
        XCTAssertFalse(document.contains("com.apple.TextEdit"))
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
