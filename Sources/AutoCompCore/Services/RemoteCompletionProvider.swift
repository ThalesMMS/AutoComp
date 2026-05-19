import Foundation

public enum RemoteCompletionError: Error, Equatable {
    case invalidBaseURL(String)
    case missingAPIKey
    case badStatus(Int, String)
    case emptyResponse
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

public struct RemoteCompletionProvider: CompletionProvider {
    public let configuration: RemoteCompletionConfiguration
    public let promptBuilder: PromptBuilder
    private let urlSession: URLSessionProtocol

    public init(
        configuration: RemoteCompletionConfiguration,
        promptBuilder: PromptBuilder = PromptBuilder(),
        urlSession: URLSessionProtocol = URLSession.shared
    ) {
        self.configuration = configuration
        self.promptBuilder = promptBuilder
        self.urlSession = urlSession
    }

    public func complete(context: TextContext) async throws -> Suggestion {
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
        request.httpBody = try JSONEncoder().encode(RemoteChatRequest(
            model: configuration.model,
            messages: [
                RemoteChatMessage(role: "system", content: "You are AutoComp, a low-latency autocomplete engine. Return only the user's likely next words. Do not explain."),
                RemoteChatMessage(role: "user", content: promptBuilder.prompt(for: context))
            ],
            maxTokens: configuration.maxTokens,
            temperature: 0.2,
            chatTemplateKwargs: ChatTemplateKwargs(enableThinking: false)
        ))

        let (data, response) = try await urlSession.data(for: request)
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw RemoteCompletionError.badStatus(http.statusCode, body)
        }

        let decoded = try JSONDecoder().decode(RemoteChatResponse.self, from: data)
        let text = decoded.choices.first?.message.content?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

        guard !text.isEmpty else {
            throw RemoteCompletionError.emptyResponse
        }

        return Suggestion(
            baseContextID: context.id,
            visibleText: sanitize(text),
            latencyMs: startedAt.duration(to: .now).milliseconds
        )
    }

    private func endpointURL(baseURL: String) -> URL? {
        guard var components = URLComponents(string: baseURL) else {
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

    private func sanitize(_ text: String) -> String {
        text
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "Completion:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
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

private extension Duration {
    var milliseconds: Int {
        let components = components
        return Int(components.seconds * 1_000 + components.attoseconds / 1_000_000_000_000_000)
    }
}
