import Foundation

public enum BackendConnectivityIssue: Equatable, Sendable {
    case missingAPIKey
    case invalidEndpoint(String)
    case offline
    case localNetworkDenied
    case unauthorized
    case modelNotFound
    case rateLimited
    case streamingUnsupported
    case timeout
    case httpStatus(Int)
    case malformedResponse
    case emptyResponse
    case transport(String)

    public var message: String {
        switch self {
        case .missingAPIKey:
            return "Remote backend API key is missing. Add an API key in Settings > Model."
        case .invalidEndpoint(let value):
            return "Remote backend endpoint is invalid: \(value). Use a full http:// or https:// URL."
        case .offline:
            return "Remote backend is unreachable because the network appears offline."
        case .localNetworkDenied:
            return "Local Network access appears blocked. Enable AutoComp in Privacy & Security > Local Network, then retry."
        case .unauthorized:
            return "Remote backend rejected the API key with 401 Unauthorized. Check the API key in Settings > Model."
        case .modelNotFound:
            return "Remote backend could not find the configured model. Check the model name in Settings > Model."
        case .rateLimited:
            return "Remote backend is rate-limiting requests with HTTP 429. Wait before retrying or reduce request frequency."
        case .streamingUnsupported:
            return "Remote backend returned a streaming response, but AutoComp requires non-streaming chat completions."
        case .timeout:
            return "Remote backend timed out. Check that the server is reachable and responding quickly."
        case .httpStatus(let statusCode):
            return "Remote backend returned HTTP \(statusCode). Check the endpoint and server logs."
        case .malformedResponse:
            return "Remote backend returned a response AutoComp could not parse."
        case .emptyResponse:
            return "Remote backend returned an empty completion."
        case .transport(let message):
            return "Remote backend request failed: \(message)"
        }
    }

    public var statusReason: String {
        switch self {
        case .missingAPIKey:
            return "Configuration"
        case .invalidEndpoint:
            return "Invalid endpoint"
        case .offline, .transport:
            return "Connection error"
        case .localNetworkDenied:
            return "Local Network"
        case .unauthorized:
            return "Unauthorized"
        case .modelNotFound:
            return "Model not found"
        case .rateLimited:
            return "Rate limited"
        case .streamingUnsupported:
            return "Streaming response"
        case .timeout:
            return "Timeout"
        case .httpStatus(let statusCode):
            return "HTTP \(statusCode)"
        case .malformedResponse:
            return "Malformed response"
        case .emptyResponse:
            return "Empty response"
        }
    }

    public var logValue: String {
        switch self {
        case .missingAPIKey:
            return "missing-api-key"
        case .invalidEndpoint:
            return "invalid-endpoint"
        case .offline:
            return "offline"
        case .localNetworkDenied:
            return "local-network-denied"
        case .unauthorized:
            return "unauthorized"
        case .modelNotFound:
            return "model-not-found"
        case .rateLimited:
            return "rate-limited"
        case .streamingUnsupported:
            return "streaming-unsupported"
        case .timeout:
            return "timeout"
        case .httpStatus(let statusCode):
            return "http-\(statusCode)"
        case .malformedResponse:
            return "malformed-response"
        case .emptyResponse:
            return "empty-response"
        case .transport:
            return "transport"
        }
    }

    public var isTransientBackendFailure: Bool {
        switch self {
        case .offline, .localNetworkDenied, .timeout, .transport:
            return true
        case .httpStatus(let statusCode):
            return (500..<600).contains(statusCode)
        case .rateLimited:
            return true
        case .missingAPIKey, .invalidEndpoint, .unauthorized, .modelNotFound, .streamingUnsupported, .malformedResponse, .emptyResponse:
            return false
        }
    }
}

public enum RemoteCompletionError: LocalizedError, Equatable, Sendable {
    case invalidBaseURL(String)
    case missingAPIKey
    case badStatus(Int, String)
    case connectivity(BackendConnectivityIssue)
    case emptyResponse

    public var issue: BackendConnectivityIssue {
        switch self {
        case .invalidBaseURL(let value):
            return .invalidEndpoint(value)
        case .missingAPIKey:
            return .missingAPIKey
        case .badStatus(401, _):
            return .unauthorized
        case .badStatus(404, _):
            return .httpStatus(404)
        case .badStatus(429, _):
            return .rateLimited
        case .badStatus(let statusCode, _):
            return .httpStatus(statusCode)
        case .connectivity(let issue):
            return issue
        case .emptyResponse:
            return .emptyResponse
        }
    }

    public var errorDescription: String? {
        issue.message
    }
}

public struct RemoteCompletionConfiguration: Codable, Equatable, Sendable {
    public var baseURL: String
    public var apiKey: String
    public var model: String
    public var maxTokens: Int
    public var timeoutSeconds: TimeInterval
    public var stopSequences: CompletionStopSequences

    public init(
        baseURL: String,
        apiKey: String,
        model: String,
        maxTokens: Int = 32,
        timeoutSeconds: TimeInterval = 2.5,
        stopSequences: CompletionStopSequences = .conservativeDefault
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.maxTokens = maxTokens
        self.timeoutSeconds = timeoutSeconds
        self.stopSequences = stopSequences
    }
}

public struct RemoteCompletionProvider: ClipboardContextAwareCompletionProvider, MultipleCompletionProvider {
    public let configuration: RemoteCompletionConfiguration
    public let requestFactory: CompletionRequestFactory
    public var promptBuilder: PromptBuilder { requestFactory.promptBuilder }
    private let urlSession: URLSessionProtocol

    public init(
        configuration: RemoteCompletionConfiguration,
        promptBuilder: PromptBuilder = PromptBuilder(),
        urlSession: URLSessionProtocol = URLSession.shared
    ) {
        self.init(
            configuration: configuration,
            requestFactory: CompletionRequestFactory(promptBuilder: promptBuilder),
            urlSession: urlSession
        )
    }

    public init(
        configuration: RemoteCompletionConfiguration,
        requestFactory: CompletionRequestFactory,
        urlSession: URLSessionProtocol = URLSession.shared
    ) {
        self.configuration = configuration
        self.requestFactory = requestFactory
        self.urlSession = urlSession
    }

    public func complete(context: TextContext) async throws -> Suggestion {
        try await complete(context: context, privacySettings: PrivacySettings(), visualContext: nil)
    }

    public func complete(
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?
    ) async throws -> Suggestion {
        try await complete(
            context: context,
            privacySettings: privacySettings,
            visualContext: visualContext,
            clipboardContext: nil
        )
    }

    public func complete(
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?,
        clipboardContext: ClipboardContextSnapshot?
    ) async throws -> Suggestion {
        let suggestions = try await complete(
            context: context,
            privacySettings: privacySettings,
            visualContext: visualContext,
            clipboardContext: clipboardContext,
            options: CompletionOptions()
        )
        guard let suggestion = suggestions.first else {
            throw RemoteCompletionError.emptyResponse
        }
        return suggestion
    }

    public func complete(
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?,
        clipboardContext: ClipboardContextSnapshot?,
        options: CompletionOptions
    ) async throws -> [Suggestion] {
        guard !configuration.apiKey.isEmpty else {
            throw RemoteCompletionError.missingAPIKey
        }

        guard let url = endpointURL(baseURL: configuration.baseURL) else {
            throw RemoteCompletionError.invalidBaseURL(configuration.baseURL)
        }

        let startedAt = ContinuousClock.now
        var request = URLRequest(url: url, timeoutInterval: configuration.timeoutSeconds)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "Authorization")
        let completionRequest = requestFactory.makeRequest(
            for: context,
            configuration: configuration,
            privacySettings: privacySettings,
            visualContext: visualContext,
            clipboardContext: clipboardContext
        )
        request.httpBody = try JSONEncoder().encode(RemoteChatRequest(
            completionRequest: completionRequest,
            suggestionCount: options.suggestionCount,
            messages: [
                RemoteChatMessage(role: "system", content: systemPrompt(for: completionRequest.mode)),
                RemoteChatMessage(role: "user", content: completionRequest.prompt)
            ]
        ))

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch let error as URLError {
            throw RemoteCompletionError.connectivity(
                BackendConnectivityClassifier.issue(for: error, endpoint: url)
            )
        } catch {
            throw RemoteCompletionError.connectivity(.transport(String(describing: error)))
        }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw RemoteCompletionError.badStatus(http.statusCode, body)
        }

        let decoded: RemoteChatResponse
        do {
            decoded = try JSONDecoder().decode(RemoteChatResponse.self, from: data)
        } catch {
            throw RemoteCompletionError.connectivity(.malformedResponse)
        }
        if decoded.isStreamingChunk {
            throw RemoteCompletionError.connectivity(.streamingUnsupported)
        }
        let suggestions = decoded.choices.compactMap { choice -> Suggestion? in
            let rawText = choice.message?.content ?? choice.text ?? ""
            let text = SuggestionTextNormalizer.normalize(
                rawText: rawText,
                request: completionRequest
            )
            guard !text.isEmpty else {
                return nil
            }
            return Suggestion(
                baseContextID: context.id,
                visibleText: text,
                rawText: rawText,
                latencyMs: startedAt.duration(to: .now).milliseconds
            )
        }.deduplicatedByVisibleText()

        guard !suggestions.isEmpty else {
            throw RemoteCompletionError.emptyResponse
        }

        return suggestions
    }

    private func systemPrompt(for mode: CompletionRequestMode) -> String {
        switch mode {
        case .continuation:
            return "You are AutoComp, a low-latency autocomplete engine. Return only the user's likely next words. Do not explain."
        case .fillInMiddle:
            return "You are AutoComp, a low-latency autocomplete engine. Fill the cursor gap and return only the text to insert. Do not repeat suffix text or explain."
        }
    }

    private func endpointURL(baseURL: String) -> URL? {
        RemoteEndpointBuilder.chatCompletionsURL(baseURL: baseURL)
    }
}

enum RemoteEndpointBuilder {
    static func chatCompletionsURL(baseURL: String) -> URL? {
        endpointURL(baseURL: baseURL, leafPath: "chat/completions")
    }

    static func modelsURL(baseURL: String) -> URL? {
        endpointURL(baseURL: baseURL, leafPath: "models")
    }

    private static func endpointURL(baseURL: String, leafPath: String) -> URL? {
        guard var components = URLComponents(string: baseURL) else {
            return nil
        }
        guard let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false else {
            return nil
        }

        let versionedPath = versionedBasePath(from: components.path)
        components.path = "/" + [versionedPath, leafPath]
            .filter { !$0.isEmpty }
            .joined(separator: "/")

        return components.url
    }

    private static func versionedBasePath(from path: String) -> String {
        var parts = path
            .split(separator: "/")
            .map(String.init)

        if Array(parts.suffix(2)) == ["chat", "completions"] {
            parts.removeLast(2)
        } else if parts.last == "models" {
            parts.removeLast()
        }

        if parts.last.map(isVersionPathComponent) != true {
            parts.append("v1")
        }

        return parts.joined(separator: "/")
    }

    private static func isVersionPathComponent(_ component: String) -> Bool {
        guard component.first == "v",
              component.count > 1 else {
            return false
        }

        return component.dropFirst().allSatisfy(\.isNumber)
    }
}

enum BackendConnectivityClassifier {
    static func issue(for error: URLError, endpoint: URL) -> BackendConnectivityIssue {
        if containsLocalNetworkDenial(error) {
            return .localNetworkDenied
        }

        switch error.code {
        case .notConnectedToInternet, .networkConnectionLost:
            return .offline
        case .timedOut:
            return .timeout
        case .cannotFindHost where isLocalNetworkEndpoint(endpoint),
             .cannotConnectToHost where isLocalNetworkEndpoint(endpoint),
             .dnsLookupFailed where isLocalNetworkEndpoint(endpoint):
            return .localNetworkDenied
        case .unsupportedURL, .badURL:
            return .invalidEndpoint(endpoint.absoluteString)
        default:
            return .transport(error.localizedDescription)
        }
    }

    private static func containsLocalNetworkDenial(_ error: URLError) -> Bool {
        let searchableValues = [error.localizedDescription]
            + error.userInfo.values.map { String(describing: $0) }
        return searchableValues.contains { value in
            value.localizedCaseInsensitiveContains("local network")
                || value.localizedCaseInsensitiveContains("local-network")
                || value.localizedCaseInsensitiveContains("prohibited")
        }
    }

    private static func isLocalNetworkEndpoint(_ endpoint: URL) -> Bool {
        guard let host = endpoint.host?.lowercased() else {
            return false
        }
        if host == "localhost" || host.hasSuffix(".local") {
            return true
        }

        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else {
            return false
        }

        if parts[0] == 10 || parts[0] == 127 || (parts[0] == 169 && parts[1] == 254) {
            return true
        }
        if parts[0] == 192 && parts[1] == 168 {
            return true
        }
        if parts[0] == 172 && (16...31).contains(parts[1]) {
            return true
        }
        if parts[0] == 100 && (64...127).contains(parts[1]) {
            return true
        }
        return false
    }
}

public protocol URLSessionProtocol: Sendable {
    func data(for request: URLRequest) async throws -> (Data, URLResponse)
}

extension URLSession: URLSessionProtocol {}

private struct RemoteChatRequest: Codable {
    let model: String
    let messages: [RemoteChatMessage]
    let maxTokens: Int
    let temperature: Double
    let n: Int?
    let stream: Bool
    let stop: [String]?
    let chatTemplateKwargs: ChatTemplateKwargs

    init(completionRequest: CompletionRequest, suggestionCount: Int = 1, messages: [RemoteChatMessage]) {
        self.model = completionRequest.model
        self.messages = messages
        self.maxTokens = completionRequest.maxTokens
        self.temperature = completionRequest.temperature
        self.n = suggestionCount > 1 ? suggestionCount : nil
        self.stream = false
        self.stop = completionRequest.stopSequences.isEmpty ? nil : completionRequest.stopSequences
        self.chatTemplateKwargs = ChatTemplateKwargs(enableThinking: false)
    }

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case maxTokens = "max_tokens"
        case temperature
        case n
        case stream
        case stop
        case chatTemplateKwargs = "chat_template_kwargs"
    }
}

private struct RemoteChatMessage: Codable {
    let role: String
    let content: String?
}

private struct ChatTemplateKwargs: Codable {
    let enableThinking: Bool

    enum CodingKeys: String, CodingKey {
        case enableThinking = "enable_thinking"
    }
}

private struct RemoteChatResponse: Codable {
    let object: String?
    let choices: [RemoteChatChoice]

    var isStreamingChunk: Bool {
        object?.localizedCaseInsensitiveContains("chunk") == true
            || choices.contains { $0.delta != nil }
    }
}

private struct RemoteChatChoice: Codable {
    let message: RemoteChatMessage?
    let text: String?
    let delta: RemoteChatMessage?
}

private extension Array where Element == Suggestion {
    func deduplicatedByVisibleText() -> [Suggestion] {
        var seen: Set<String> = []
        var result: [Suggestion] = []
        for suggestion in self {
            let key = suggestion.visibleText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !key.isEmpty, !seen.contains(key) else {
                continue
            }
            seen.insert(key)
            result.append(suggestion)
        }
        return result
    }
}
