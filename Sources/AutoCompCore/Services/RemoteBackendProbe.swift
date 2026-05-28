import Foundation

public enum RemoteBackendProbeStatus: String, Equatable, Sendable {
    case connected
    case failed
}

public struct RemoteBackendProbeResult: Equatable, Sendable {
    public let status: RemoteBackendProbeStatus
    public let message: String
    public let suggestedModel: String?
    public let issue: BackendConnectivityIssue?

    public init(
        status: RemoteBackendProbeStatus,
        message: String,
        suggestedModel: String? = nil,
        issue: BackendConnectivityIssue? = nil
    ) {
        self.status = status
        self.message = message
        self.suggestedModel = suggestedModel
        self.issue = issue
    }
}

public struct RemoteBackendProbe: Sendable {
    private let urlSession: URLSessionProtocol

    public init(urlSession: URLSessionProtocol = URLSession.shared) {
        self.urlSession = urlSession
    }

    public func testConnection(
        configuration: RemoteCompletionConfiguration
    ) async -> RemoteBackendProbeResult {
        guard let modelsURL = RemoteEndpointBuilder.modelsURL(baseURL: configuration.baseURL),
              let completionsURL = RemoteEndpointBuilder.chatCompletionsURL(baseURL: configuration.baseURL) else {
            let issue = BackendConnectivityIssue.invalidEndpoint(configuration.baseURL)
            return failure(issue)
        }

        let modelsResult = await requestModels(url: modelsURL, configuration: configuration)
        switch modelsResult {
        case .connected(let suggestedModel, let configuredModelAvailable):
            if !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !configuredModelAvailable {
                return failure(.modelNotFound)
            }
            if let suggestedModel {
                return RemoteBackendProbeResult(
                    status: .connected,
                    message: "Connected. Suggested model: \(suggestedModel)",
                    suggestedModel: suggestedModel
                )
            }
            return RemoteBackendProbeResult(status: .connected, message: "Connected")
        case .failed(let issue) where issue == .unauthorized:
            return failure(issue)
        case .failed:
            guard !configuration.model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return RemoteBackendProbeResult(
                    status: .failed,
                    message: "Remote backend did not return a model list. Enter a model name, then test again.",
                    issue: .malformedResponse
                )
            }
        }

        return await requestCompletion(url: completionsURL, configuration: configuration)
    }

    private func requestModels(
        url: URL,
        configuration: RemoteCompletionConfiguration
    ) async -> ModelsProbeResult {
        var request = URLRequest(url: url, timeoutInterval: configuration.timeoutSeconds)
        request.httpMethod = "GET"
        applyHeaders(to: &request, apiKey: configuration.apiKey)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await urlSession.data(for: request)
        } catch let error as URLError {
            return .failed(BackendConnectivityClassifier.issue(for: error, endpoint: url))
        } catch {
            return .failed(.transport(String(describing: error)))
        }

        guard let http = response as? HTTPURLResponse else {
            return .failed(.transport("Missing HTTP response."))
        }
        guard (200..<300).contains(http.statusCode) else {
            return .failed(issue(forHTTPStatus: http.statusCode))
        }

        guard let decoded = try? JSONDecoder().decode(RemoteModelsResponse.self, from: data) else {
            return .failed(.malformedResponse)
        }

        let modelIDs = decoded.data
            .map { $0.id.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let suggestedModel = modelIDs.first
        let configuredModel = configuration.model.trimmingCharacters(in: .whitespacesAndNewlines)
        let configuredModelAvailable = configuredModel.isEmpty || modelIDs.contains(configuredModel)
        return .connected(suggestedModel, configuredModelAvailable: configuredModelAvailable)
    }

    private func requestCompletion(
        url: URL,
        configuration: RemoteCompletionConfiguration
    ) async -> RemoteBackendProbeResult {
        var request = URLRequest(url: url, timeoutInterval: configuration.timeoutSeconds)
        request.httpMethod = "POST"
        applyHeaders(to: &request, apiKey: configuration.apiKey)
        request.httpBody = try? JSONEncoder().encode(RemoteProbeCompletionRequest(
            model: configuration.model,
            messages: [
                RemoteProbeChatMessage(role: "user", content: "Return OK only.")
            ],
            maxTokens: min(configuration.maxTokens, 4),
            temperature: 0
        ))

        let response: URLResponse
        do {
            (_, response) = try await urlSession.data(for: request)
        } catch let error as URLError {
            return failure(BackendConnectivityClassifier.issue(for: error, endpoint: url))
        } catch {
            return failure(.transport(String(describing: error)))
        }

        guard let http = response as? HTTPURLResponse else {
            return failure(.transport("Missing HTTP response."))
        }
        guard (200..<300).contains(http.statusCode) else {
            return failure(issue(forHTTPStatus: http.statusCode))
        }

        return RemoteBackendProbeResult(status: .connected, message: "Connected")
    }

    private func applyHeaders(to request: inout URLRequest, apiKey: String) {
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }

    private func issue(forHTTPStatus statusCode: Int) -> BackendConnectivityIssue {
        switch statusCode {
        case 401:
            return .unauthorized
        case 404:
            return .httpStatus(404)
        case 429:
            return .rateLimited
        default:
            return .httpStatus(statusCode)
        }
    }

    private func failure(_ issue: BackendConnectivityIssue) -> RemoteBackendProbeResult {
        RemoteBackendProbeResult(
            status: .failed,
            message: issue.message,
            issue: issue
        )
    }
}

private enum ModelsProbeResult: Equatable {
    case connected(String?, configuredModelAvailable: Bool)
    case failed(BackendConnectivityIssue)
}

private struct RemoteModelsResponse: Decodable {
    let data: [RemoteModel]
}

private struct RemoteModel: Decodable {
    let id: String
}

private struct RemoteProbeCompletionRequest: Encodable {
    let model: String
    let messages: [RemoteProbeChatMessage]
    let maxTokens: Int
    let temperature: Double

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case maxTokens = "max_tokens"
        case temperature
    }
}

private struct RemoteProbeChatMessage: Encodable {
    let role: String
    let content: String
}
