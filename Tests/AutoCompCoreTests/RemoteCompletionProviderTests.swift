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
                data: Data(#"{"choices":[{"message":{"role":"assistant","content":" review this today."}}]}"#.utf8),
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
}

private struct MockURLSession: URLSessionProtocol {
    let data: Data
    let response: URLResponse

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:8000/v1/chat/completions")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test")
        let body = try? JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any]
        let template = body?["chat_template_kwargs"] as? [String: Any]
        XCTAssertEqual(template?["enable_thinking"] as? Bool, false)
        return (data, response)
    }
}
