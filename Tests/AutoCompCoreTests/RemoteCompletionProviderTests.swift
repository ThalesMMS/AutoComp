import AutoCompCore
import Foundation
import XCTest

final class RemoteCompletionProviderTests: XCTestCase {
    func testParsesOpenAICompatibleResponse() async throws {
        let context = TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: "Can you"
        )
        let provider = RemoteCompletionProvider(
            configuration: RemoteCompletionConfiguration(
                baseURL: "http://127.0.0.1:8000",
                apiKey: "test",
                model: "Qwen/Qwen3.6-35B-A3B"
            ),
            urlSession: MockURLSession(
                data: Data(#"{"choices":[{"message":{"role":"assistant","content":"review this today."}}]}"#.utf8),
                response: HTTPURLResponse(
                    url: URL(string: "http://127.0.0.1:8000/v1/chat/completions")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        )

        let suggestion = try await provider.complete(context: context)

        XCTAssertEqual(suggestion.visibleText, "review this today.")
    }

    func testNormalizesCompletionLabelAndNewlineInResponse() async throws {
        let context = TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: "Can you "
        )
        let provider = RemoteCompletionProvider(
            configuration: RemoteCompletionConfiguration(
                baseURL: "http://127.0.0.1:8000",
                apiKey: "test",
                model: "Qwen/Qwen3.6-35B-A3B"
            ),
            urlSession: MockURLSession(
                data: Data(#"{"choices":[{"message":{"role":"assistant","content":"Completion:\n review this today.\nignore this line"}}]}"#.utf8),
                response: HTTPURLResponse(
                    url: URL(string: "http://127.0.0.1:8000/v1/chat/completions")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        )

        let suggestion = try await provider.complete(context: context)

        XCTAssertEqual(suggestion.visibleText, "review this today.")
    }

    func testThrowsEmptyResponseAfterNormalization() async throws {
        let context = TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: "Can you "
        )
        let provider = RemoteCompletionProvider(
            configuration: RemoteCompletionConfiguration(
                baseURL: "http://127.0.0.1:8000",
                apiKey: "test",
                model: "Qwen/Qwen3.6-35B-A3B"
            ),
            urlSession: MockURLSession(
                data: Data(#"{"choices":[{"message":{"role":"assistant","content":"Completion:\n\n"}}]}"#.utf8),
                response: HTTPURLResponse(
                    url: URL(string: "http://127.0.0.1:8000/v1/chat/completions")!,
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        )

        do {
            _ = try await provider.complete(context: context)
            XCTFail("Expected emptyResponse after normalization")
        } catch let error as RemoteCompletionError {
            XCTAssertEqual(error, .emptyResponse)
        }
    }

    func testInvalidEndpointMapsToActionableMessage() async throws {
        let provider = RemoteCompletionProvider(
            configuration: RemoteCompletionConfiguration(
                baseURL: "not-a-url",
                apiKey: "test",
                model: "Qwen/Qwen3.6-35B-A3B"
            ),
            urlSession: ThrowingURLSession(error: URLError(.badURL))
        )

        do {
            _ = try await provider.complete(context: makeContext())
            XCTFail("Expected invalid endpoint error")
        } catch let error as RemoteCompletionError {
            XCTAssertEqual(error.issue, .invalidEndpoint("not-a-url"))
            XCTAssertEqual(
                error.errorDescription,
                "Remote backend endpoint is invalid: not-a-url. Use a full http:// or https:// URL."
            )
        }
    }

    func testUnauthorizedStatusMapsToActionableMessage() async throws {
        let provider = RemoteCompletionProvider(
            configuration: RemoteCompletionConfiguration(
                baseURL: "http://127.0.0.1:8000",
                apiKey: "test",
                model: "Qwen/Qwen3.6-35B-A3B"
            ),
            urlSession: MockURLSession(
                data: Data("unauthorized".utf8),
                response: HTTPURLResponse(
                    url: URL(string: "http://127.0.0.1:8000/v1/chat/completions")!,
                    statusCode: 401,
                    httpVersion: nil,
                    headerFields: nil
                )!
            )
        )

        do {
            _ = try await provider.complete(context: makeContext())
            XCTFail("Expected unauthorized error")
        } catch let error as RemoteCompletionError {
            XCTAssertEqual(error.issue, .unauthorized)
            XCTAssertEqual(
                error.errorDescription,
                "Remote backend rejected the API key with 401 Unauthorized. Check the API key in Settings > Model."
            )
        }
    }

    func testURLErrorMappingCoversOfflineTimeoutAndLocalNetworkDenied() async throws {
        let offline = try await remoteError(for: URLError(.notConnectedToInternet))
        let timeout = try await remoteError(for: URLError(.timedOut))
        let localNetworkDenied = try await remoteError(
            for: URLError(
                .notConnectedToInternet,
                userInfo: [NSLocalizedDescriptionKey: "Connection blocked: Local Network prohibited"]
            )
        )

        XCTAssertEqual(offline.issue, .offline)
        XCTAssertEqual(timeout.issue, .timeout)
        XCTAssertEqual(localNetworkDenied.issue, .localNetworkDenied)
        XCTAssertEqual(
            localNetworkDenied.errorDescription,
            "Local Network access appears blocked. Enable AutoComp in Privacy & Security > Local Network, then retry."
        )
    }

    func testRequestIncludesVisualContextWhenAllowed() async throws {
        let context = TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: "Can you "
        )
        let provider = RemoteCompletionProvider(
            configuration: RemoteCompletionConfiguration(
                baseURL: "http://127.0.0.1:8000",
                apiKey: "test",
                model: "Qwen/Qwen3.6-35B-A3B"
            ),
            urlSession: MockURLSession(
                data: Data(#"{"choices":[{"message":{"role":"assistant","content":"review this today."}}]}"#.utf8),
                response: okResponse(),
                expectedPromptContains: "Visual context:\nVisible title Budget Review",
                forbiddenPromptContains: nil
            )
        )

        _ = try await provider.complete(
            context: context,
            privacySettings: PrivacySettings(screenContextEnabled: true),
            visualContext: VisualContextSnapshot(summary: "Visible title Budget Review")
        )
    }

    func testRequestOmitsVisualContextWhenBlockedByPrivacy() async throws {
        let context = TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: "Can you "
        )
        let provider = RemoteCompletionProvider(
            configuration: RemoteCompletionConfiguration(
                baseURL: "http://127.0.0.1:8000",
                apiKey: "test",
                model: "Qwen/Qwen3.6-35B-A3B"
            ),
            urlSession: MockURLSession(
                data: Data(#"{"choices":[{"message":{"role":"assistant","content":"review this today."}}]}"#.utf8),
                response: okResponse(),
                forbiddenPromptContains: "Visual context:"
            )
        )

        _ = try await provider.complete(
            context: context,
            privacySettings: PrivacySettings(screenContextEnabled: false),
            visualContext: VisualContextSnapshot(summary: "Visible title Budget Review")
        )
    }

    func testRequestOmitsVisualContextWhenUnavailable() async throws {
        let context = TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: "Can you "
        )
        let provider = RemoteCompletionProvider(
            configuration: RemoteCompletionConfiguration(
                baseURL: "http://127.0.0.1:8000",
                apiKey: "test",
                model: "Qwen/Qwen3.6-35B-A3B"
            ),
            urlSession: MockURLSession(
                data: Data(#"{"choices":[{"message":{"role":"assistant","content":"review this today."}}]}"#.utf8),
                response: okResponse(),
                forbiddenPromptContains: "Visual context:"
            )
        )

        _ = try await provider.complete(
            context: context,
            privacySettings: PrivacySettings(screenContextEnabled: true),
            visualContext: nil
        )
    }

    private func okResponse() -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "http://127.0.0.1:8000/v1/chat/completions")!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil
        )!
    }

    private func makeContext() -> TextContext {
        TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: "Can you "
        )
    }

    private func remoteError(for underlyingError: Error) async throws -> RemoteCompletionError {
        let provider = RemoteCompletionProvider(
            configuration: RemoteCompletionConfiguration(
                baseURL: "http://100.98.1.45:8000",
                apiKey: "test",
                model: "Qwen/Qwen3.6-35B-A3B"
            ),
            urlSession: ThrowingURLSession(error: underlyingError)
        )

        do {
            _ = try await provider.complete(context: makeContext())
            XCTFail("Expected remote error")
            throw RemoteCompletionError.emptyResponse
        } catch let error as RemoteCompletionError {
            return error
        }
    }
}

private struct MockURLSession: URLSessionProtocol {
    let data: Data
    let response: URLResponse
    var expectedPromptContains: String?
    var forbiddenPromptContains: String? = "Visual context:"

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8000/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test")
        let body = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        XCTAssertEqual(body?["model"] as? String, "Qwen/Qwen3.6-35B-A3B")
        XCTAssertEqual(body?["max_tokens"] as? Int, 32)
        XCTAssertEqual(body?["temperature"] as? Double, 0.2)
        let template = body?["chat_template_kwargs"] as? [String: Any]
        XCTAssertEqual(template?["enable_thinking"] as? Bool, false)
        let messages = body?["messages"] as? [[String: Any]]
        let userPrompt = messages?.first { $0["role"] as? String == "user" }?["content"] as? String
        if let expectedPromptContains {
            XCTAssertTrue(userPrompt?.contains(expectedPromptContains) == true)
        }
        if let forbiddenPromptContains {
            XCTAssertFalse(userPrompt?.contains(forbiddenPromptContains) == true)
        }
        return (data, response)
    }
}

private struct ThrowingURLSession: URLSessionProtocol {
    let error: Error

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw error
    }
}
