import Foundation

public enum BackendConnectivityIssue: Equatable, Sendable {
    case missingAPIKey
    case invalidEndpoint(String)
    case offline
    case localNetworkDenied
    case unauthorized
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
}

public enum RemoteCompletionError: LocalizedError, Equatable {
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

    public init(
        baseURL: String,
        apiKey: String,
        model: String,
        maxTokens: Int = 32,
        timeoutSeconds: TimeInterval = 2.5
    ) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.model = model
        self.maxTokens = maxTokens
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct RemoteCompletionProvider: VisualContextAwareCompletionProvider {
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
            visualContext: visualContext
        )
        request.httpBody = try JSONEncoder().encode(RemoteChatRequest(
            completionRequest: completionRequest,
            messages: [
                RemoteChatMessage(role: "system", content: "You are AutoComp, a low-latency autocomplete engine. Return only the user's likely next words. Do not explain."),
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
        let rawText = decoded.choices.first?.message.content ?? ""
        let text = SuggestionTextNormalizer.normalize(
            rawText: rawText,
            precedingText: context.textBeforeCursor,
            promptEchoCandidates: completionRequest.promptEchoCandidates
        )

        guard !text.isEmpty else {
            throw RemoteCompletionError.emptyResponse
        }

        return Suggestion(
            baseContextID: context.id,
            visibleText: text,
            rawText: rawText,
            latencyMs: startedAt.duration(to: .now).milliseconds
        )
    }

    private func endpointURL(baseURL: String) -> URL? {
        guard var components = URLComponents(string: baseURL) else {
            return nil
        }
        guard let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              components.host?.isEmpty == false else {
            return nil
        }

        let path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        if path.isEmpty {
            components.path = "/v1/chat/completions"
        } else if !path.hasSuffix("chat/completions") {
            components.path = "/" + path + "/v1/chat/completions"
        }

        return components.url
    }
}

private enum BackendConnectivityClassifier {
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
    let chatTemplateKwargs: ChatTemplateKwargs

    init(completionRequest: CompletionRequest, messages: [RemoteChatMessage]) {
        self.model = completionRequest.model
        self.messages = messages
        self.maxTokens = completionRequest.maxTokens
        self.temperature = completionRequest.temperature
        self.chatTemplateKwargs = ChatTemplateKwargs(enableThinking: false)
    }

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case maxTokens = "max_tokens"
        case temperature
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
    let choices: [RemoteChatChoice]
}

private struct RemoteChatChoice: Codable {
    let message: RemoteChatMessage
}
