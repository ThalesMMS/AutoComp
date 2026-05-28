import AutoCompCore
import Foundation

struct CompletionPlaygroundPreview: Equatable {
    let context: TextContext
    let request: CompletionRequest
    let requestDestinationTitle: String
    let dataLeavesDeviceTitle: String
    let remoteFallbackTitle: String

    var modeTitle: String {
        switch request.mode {
        case .continuation:
            return "Continuation"
        case .fillInMiddle:
            return "Fill in middle"
        }
    }

    func promptPreview(options: AutoCompDebugOptions) -> String? {
        if options.allowsSensitivePromptPreview {
            return request.prompt
        }
        return redactedPromptPreview
    }

    private var redactedPromptPreview: String {
        """
        Sensitive prompt content hidden until local debug opt-in is enabled.
        Mode: \(modeTitle)
        Prompt size: chars=\(request.prompt.count) bytes=\(request.prompt.utf8.count)
        Text before cursor: chars=\(request.truncatedTextBeforeCursor.count)
        Text after cursor: \(optionalCount(request.truncatedTextAfterCursor))
        Selected text: \(optionalCount(request.truncatedSelectedText))
        Full text window: \(optionalCount(request.truncatedFullTextWindow))
        \(clipboardContextSummary)
        \(visualContextSummary)
        Capture sources: count=\(request.allowedCaptureSources.count)
        Echo candidates: count=\(request.promptEchoCandidates.count)
        """
    }

    private var clipboardContextSummary: String {
        guard let clipboardContext = request.clipboardContext else {
            return "Clipboard context: none"
        }

        if clipboardContext.isIncluded {
            return "Clipboard context: included chars=\(clipboardContext.summary.count) sources=\(clipboardContext.captureSources.count)"
        }

        return "Clipboard context: omitted status=\(clipboardContext.status.rawValue) sources=\(clipboardContext.captureSources.count)"
    }

    private var visualContextSummary: String {
        guard let visualContext = request.visualContext else {
            return "Visual context: none"
        }

        return "Visual context: included chars=\(visualContext.summary.count) sources=\(visualContext.captureSources.count)"
    }

    private func optionalCount(_ text: String?) -> String {
        guard let text else {
            return "none"
        }
        return "chars=\(text.count)"
    }
}

struct CompletionPlaygroundResult: Equatable {
    let preview: CompletionPlaygroundPreview
    let rawOutput: String
    let normalizedOutput: String
    let latencyMs: Int
}

struct CompletionPlaygroundService {
    var requestFactory = CompletionRequestFactory()

    func preview(
        prefix: String,
        suffix: String,
        settings: CompletionBackendSettings
    ) -> CompletionPlaygroundPreview {
        let context = makeContext(prefix: prefix, suffix: suffix)
        let request = requestFactory.makeRequest(
            for: context,
            configuration: requestConfiguration(for: settings)
        )
        return CompletionPlaygroundPreview(
            context: context,
            request: request,
            requestDestinationTitle: settings.requestDestinationTitle,
            dataLeavesDeviceTitle: settings.dataLeavesDeviceTitle,
            remoteFallbackTitle: settings.remoteFallbackTitle
        )
    }

    func complete(
        prefix: String,
        suffix: String,
        settings: CompletionBackendSettings,
        provider: CompletionProvider
    ) async throws -> CompletionPlaygroundResult {
        let preview = preview(prefix: prefix, suffix: suffix, settings: settings)
        let suggestion = try await provider.complete(context: preview.context)
        return CompletionPlaygroundResult(
            preview: preview,
            rawOutput: suggestion.rawText ?? suggestion.visibleText,
            normalizedOutput: suggestion.visibleText,
            latencyMs: suggestion.latencyMs
        )
    }

    private func makeContext(prefix: String, suffix: String) -> TextContext {
        TextContext(
            app: AppIdentity(
                bundleID: "com.autocomp.playground",
                displayName: "AutoComp Playground",
                processID: Int32(ProcessInfo.processInfo.processIdentifier)
            ),
            focusedElementID: "settings-playground",
            textBeforeCursor: prefix,
            textAfterCursor: suffix.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : suffix,
            fullTextWindow: prefix + suffix,
            captureSources: [.accessibility]
        )
    }

    private func requestConfiguration(for settings: CompletionBackendSettings) -> RemoteCompletionConfiguration {
        switch settings.engineKind {
        case .remote:
            return settings.remoteConfiguration
        case .localLlama:
            return RemoteCompletionConfiguration(
                baseURL: "local://in-process",
                apiKey: "local",
                model: settings.localConfiguration.modelName,
                maxTokens: settings.localConfiguration.maxTokens,
                stopSequences: settings.stopSequences
            )
        case .appleIntelligence:
            return RemoteCompletionConfiguration(
                baseURL: "apple://foundation-models",
                apiKey: "apple",
                model: "apple-intelligence",
                stopSequences: settings.stopSequences
            )
        }
    }
}
