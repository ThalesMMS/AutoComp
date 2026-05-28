import AutoCompCore
import Foundation

enum ModelCompatibilityBackendClass: String, Codable, CaseIterable, Sendable {
    case remoteOpenAICompatible
    case localServerBridge
    case appleIntelligence
    case localLlamaInProcess

    var title: String {
        switch self {
        case .remoteOpenAICompatible:
            return "Remote OpenAI-compatible"
        case .localServerBridge:
            return "Local server bridge"
        case .appleIntelligence:
            return "Apple Intelligence"
        case .localLlamaInProcess:
            return "Local in-process Llama"
        }
    }
}

enum ModelCompatibilitySupport: String, Codable, Sendable {
    case supported
    case unsupported
    case unknown
    case skipped

    var title: String {
        switch self {
        case .supported:
            return "Supported by evidence"
        case .unsupported:
            return "Not supported"
        case .unknown:
            return "Unknown"
        case .skipped:
            return "Skipped"
        }
    }
}

struct ModelCompatibilityEvidenceRow: Identifiable, Codable, Equatable, Sendable {
    let id: String
    let backendClass: ModelCompatibilityBackendClass
    let backendModel: String
    let modelMatch: String?
    let runtimeLifecycle: String
    let fimSupport: ModelCompatibilitySupport
    let multipleCompletions: ModelCompatibilitySupport
    let averageLatencyMs: Int?
    let latencySource: String
    let promptEchoTendency: String
    let stopSequencesNeeded: String
    let recommendedMaxTokens: Int
    let normalizerQuirks: String
    let evidenceDate: String
    let autoCompBuild: String
    let backendVersion: String
    let skippedOrUnknownReason: String?

    var fimRecommendationTitle: String {
        switch fimSupport {
        case .supported:
            return "FIM optimized behavior supported by matrix evidence."
        case .unsupported:
            return "FIM optimized behavior not recommended for this row."
        case .unknown, .skipped:
            return "FIM optimized behavior not recommended without evidence."
        }
    }

    var latencyTitle: String {
        if let averageLatencyMs {
            return "\(averageLatencyMs) ms average; \(latencySource)"
        }
        if let skippedOrUnknownReason {
            return "Unknown or skipped: \(skippedOrUnknownReason)"
        }
        return "Unknown or skipped: no non-content latency report recorded."
    }

    var evidenceTitle: String {
        "\(evidenceDate), \(autoCompBuild), \(backendVersion)"
    }
}

struct ModelCompatibilityRecommendation: Equatable, Sendable {
    let row: ModelCompatibilityEvidenceRow?
    let rowTitle: String
    let fimTitle: String
    let multipleCompletionsTitle: String
    let latencyTitle: String
    let evidenceTitle: String
    let detail: String
}

struct ModelCompatibilityMatrix: Equatable, Sendable {
    let rows: [ModelCompatibilityEvidenceRow]

    static let bundled = ModelCompatibilityMatrix(rows: [
        ModelCompatibilityEvidenceRow(
            id: "remote-openai-compatible-generic",
            backendClass: .remoteOpenAICompatible,
            backendModel: "Configured remote model",
            modelMatch: nil,
            runtimeLifecycle: "Endpoint-managed outside AutoComp.",
            fimSupport: .unknown,
            multipleCompletions: .unknown,
            averageLatencyMs: nil,
            latencySource: "No endpoint-specific redacted latency report has been copied into the matrix.",
            promptEchoTendency: "Unknown; normalizer coverage handles common prompt, wrapper, marker, and suffix echoes.",
            stopSequencesNeeded: "Default prompt-control stops are sent through the OpenAI-compatible stop parameter.",
            recommendedMaxTokens: 32,
            normalizerQuirks: "Keep FIM marker, completion label, code fence, and suffix echo normalization enabled.",
            evidenceDate: "2026-05-27",
            autoCompBuild: "develop@3fd9877",
            backendVersion: "Unknown; remote providers vary by endpoint.",
            skippedOrUnknownReason: "Endpoint-specific behavior must be measured before claiming FIM, multi-completion, or latency support."
        ),
        ModelCompatibilityEvidenceRow(
            id: "local-server-vllm-default",
            backendClass: .localServerBridge,
            backendModel: "default",
            modelMatch: "default",
            runtimeLifecycle: "Local server lifecycle is owned by the bridge process.",
            fimSupport: .unknown,
            multipleCompletions: .unknown,
            averageLatencyMs: nil,
            latencySource: "Models/version probe only; no #124 redacted latency report was recorded for this row.",
            promptEchoTendency: "Unknown; the row does not retain model output.",
            stopSequencesNeeded: "Default prompt-control stops are sent through the OpenAI-compatible stop parameter.",
            recommendedMaxTokens: 32,
            normalizerQuirks: "Keep FIM marker and suffix echo normalization enabled until bridge-specific output evidence exists.",
            evidenceDate: "2026-05-27",
            autoCompBuild: "develop@3fd9877",
            backendVersion: "vLLM 0.21.0; /v1/models id default, max_model_len 262144.",
            skippedOrUnknownReason: "Only non-content /version and /v1/models metadata were collected."
        ),
        ModelCompatibilityEvidenceRow(
            id: "apple-foundationmodels-system",
            backendClass: .appleIntelligence,
            backendModel: "System FoundationModels session",
            modelMatch: nil,
            runtimeLifecycle: "Available only when FoundationModels is present and the system model is available.",
            fimSupport: .unknown,
            multipleCompletions: .unsupported,
            averageLatencyMs: nil,
            latencySource: "No #124 redacted latency report has been copied into the matrix.",
            promptEchoTendency: "Unknown; Apple does not expose a stable model identifier here.",
            stopSequencesNeeded: "Stop sequences are post-generation trimming fallback only.",
            recommendedMaxTokens: 32,
            normalizerQuirks: "Keep generic wrapper, marker, and suffix echo normalization enabled.",
            evidenceDate: "2026-05-27",
            autoCompBuild: "develop@3fd9877",
            backendVersion: "System availability only; exact model/version not exposed.",
            skippedOrUnknownReason: "Exact model and latency are unavailable without a local run on a supported system."
        ),
        ModelCompatibilityEvidenceRow(
            id: "local-llama-qwen3-0_6b-q4",
            backendClass: .localLlamaInProcess,
            backendModel: "Qwen3 0.6B Q4",
            modelMatch: "Qwen3-0.6B-Q4_K_M.gguf",
            runtimeLifecycle: "Opt-in llama.cpp runtime; load/unload/allocation state is tracked by local diagnostics.",
            fimSupport: .unknown,
            multipleCompletions: .unsupported,
            averageLatencyMs: nil,
            latencySource: "Default headless CI does not link the runtime; no #124 redacted latency sample was recorded.",
            promptEchoTendency: "Unknown; output evidence has not been recorded for this quantization.",
            stopSequencesNeeded: "Default prompt-control stops are applied in the local generation loop.",
            recommendedMaxTokens: 32,
            normalizerQuirks: "Keep FIM marker and suffix echo normalization enabled.",
            evidenceDate: "2026-05-27",
            autoCompBuild: "develop@3fd9877",
            backendVersion: "llama.cpp runtime version not captured by default builds.",
            skippedOrUnknownReason: "Runtime is opt-in and was not linked in the default CI evidence run."
        ),
        ModelCompatibilityEvidenceRow(
            id: "local-llama-gemma-4-e2b-q4",
            backendClass: .localLlamaInProcess,
            backendModel: "Gemma 4 E2B Q4",
            modelMatch: "gemma-4-E2B-it-Q4_K_M.gguf",
            runtimeLifecycle: "Opt-in llama.cpp runtime; load/unload/allocation state is tracked by local diagnostics.",
            fimSupport: .unknown,
            multipleCompletions: .unsupported,
            averageLatencyMs: nil,
            latencySource: "Default headless CI does not link the runtime; no #124 redacted latency sample was recorded.",
            promptEchoTendency: "Unknown; output evidence has not been recorded for this quantization.",
            stopSequencesNeeded: "Default prompt-control stops are applied in the local generation loop.",
            recommendedMaxTokens: 32,
            normalizerQuirks: "Keep FIM marker and suffix echo normalization enabled.",
            evidenceDate: "2026-05-27",
            autoCompBuild: "develop@3fd9877",
            backendVersion: "llama.cpp runtime version not captured by default builds.",
            skippedOrUnknownReason: "Runtime is opt-in and was not linked in the default CI evidence run."
        ),
        ModelCompatibilityEvidenceRow(
            id: "local-llama-generic-gguf",
            backendClass: .localLlamaInProcess,
            backendModel: "Other GGUF model",
            modelMatch: nil,
            runtimeLifecycle: "Opt-in llama.cpp runtime; load/unload/allocation state is tracked by local diagnostics.",
            fimSupport: .unknown,
            multipleCompletions: .unsupported,
            averageLatencyMs: nil,
            latencySource: "No model-specific #124 redacted latency report has been copied into the matrix.",
            promptEchoTendency: "Unknown; output evidence is model-specific.",
            stopSequencesNeeded: "Default prompt-control stops are applied in the local generation loop.",
            recommendedMaxTokens: 32,
            normalizerQuirks: "Keep conservative normalizer coverage enabled until model-specific evidence exists.",
            evidenceDate: "2026-05-27",
            autoCompBuild: "develop@3fd9877",
            backendVersion: "llama.cpp runtime version not captured by default builds.",
            skippedOrUnknownReason: "Generic fallback row; measure the concrete GGUF before recommending optimized behavior."
        )
    ])

    func recommendation(for settings: CompletionBackendSettings) -> ModelCompatibilityRecommendation {
        guard let row = bestRow(for: settings) else {
            return ModelCompatibilityRecommendation(
                row: nil,
                rowTitle: "No matrix row",
                fimTitle: "FIM optimized behavior not recommended without evidence.",
                multipleCompletionsTitle: "Unknown",
                latencyTitle: "Unknown or skipped: no matching evidence row.",
                evidenceTitle: "No evidence metadata",
                detail: "Add a manual matrix row before making model-specific recommendations."
            )
        }

        return ModelCompatibilityRecommendation(
            row: row,
            rowTitle: "\(row.backendClass.title): \(row.backendModel)",
            fimTitle: row.fimRecommendationTitle,
            multipleCompletionsTitle: row.multipleCompletions.title,
            latencyTitle: row.latencyTitle,
            evidenceTitle: row.evidenceTitle,
            detail: row.skippedOrUnknownReason ?? "Evidence row is complete."
        )
    }

    func bestRow(for settings: CompletionBackendSettings) -> ModelCompatibilityEvidenceRow? {
        let backendClass = backendClass(for: settings)
        let modelKey = modelKey(for: settings)
        return rows
            .filter { $0.backendClass == backendClass }
            .max { score($0, modelKey: modelKey) < score($1, modelKey: modelKey) }
    }

    private func score(_ row: ModelCompatibilityEvidenceRow, modelKey: String) -> Int {
        guard let match = row.modelMatch?.lowercased(), !match.isEmpty else {
            return 1
        }
        if modelKey == match {
            return 3
        }
        if modelKey.contains(match) || match.contains(modelKey) {
            return 2
        }
        return 0
    }

    private func backendClass(for settings: CompletionBackendSettings) -> ModelCompatibilityBackendClass {
        switch settings.engineKind {
        case .remote:
            return Self.isLocalServerBridge(settings.remoteBaseURL)
                ? .localServerBridge
                : .remoteOpenAICompatible
        case .localLlama:
            return .localLlamaInProcess
        case .appleIntelligence:
            return .appleIntelligence
        }
    }

    private func modelKey(for settings: CompletionBackendSettings) -> String {
        switch settings.engineKind {
        case .remote:
            return settings.remoteModel.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        case .localLlama:
            return URL(fileURLWithPath: settings.localModelPath).lastPathComponent.lowercased()
        case .appleIntelligence:
            return ""
        }
    }

    private static func isLocalServerBridge(_ baseURL: String) -> Bool {
        guard let host = URL(string: baseURL)?.host?.lowercased() else {
            return false
        }
        if host == "localhost" || host == "::1" || host == "0.0.0.0" || host.hasPrefix("127.") {
            return true
        }
        let octets = host.split(separator: ".").compactMap { Int($0) }
        guard octets.count == 4 else {
            return false
        }
        if octets[0] == 10 || (octets[0] == 192 && octets[1] == 168) {
            return true
        }
        if octets[0] == 172 && (16...31).contains(octets[1]) {
            return true
        }
        if octets[0] == 100 && (64...127).contains(octets[1]) {
            return true
        }
        return false
    }
}
