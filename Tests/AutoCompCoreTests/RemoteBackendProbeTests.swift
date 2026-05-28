import AutoCompCore
import XCTest

final class RemoteBackendProbeTests: XCTestCase {
    func testInvalidURLReturnsActionableFailureWithoutRequest() async {
        let probe = RemoteBackendProbe(urlSession: FailingIfCalledURLSession())

        let result = await probe.testConnection(configuration: configuration(baseURL: "not-a-url"))

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.issue, .invalidEndpoint("not-a-url"))
        XCTAssertTrue(result.message.contains("endpoint is invalid"))
    }

    func testTimeoutMapsToActionableFailure() async {
        let probe = RemoteBackendProbe(urlSession: ThrowingProbeURLSession(error: URLError(.timedOut)))

        let result = await probe.testConnection(configuration: configuration())

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.issue, .timeout)
        XCTAssertTrue(result.message.contains("timed out"))
    }

    func testUnauthorizedModelsResponseIsReportedWithoutCompletionFallback() async {
        let probe = RemoteBackendProbe(urlSession: ProbeMockURLSession(
            data: Data(),
            statusCode: 401,
            expectedPath: "/v1/models"
        ))

        let result = await probe.testConnection(configuration: configuration())

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.issue, .unauthorized)
        XCTAssertTrue(result.message.contains("401 Unauthorized"))
    }

    func testOKModelsResponseSuggestsModelWhenAvailable() async {
        let data = Data("""
        {"data":[{"id":"local-model"}]}
        """.utf8)
        let probe = RemoteBackendProbe(urlSession: ProbeMockURLSession(
            data: data,
            statusCode: 200,
            expectedPath: "/v1/models"
        ))

        let result = await probe.testConnection(configuration: configuration(model: ""))

        XCTAssertEqual(result.status, .connected)
        XCTAssertEqual(result.suggestedModel, "local-model")
        XCTAssertTrue(result.message.contains("Suggested model: local-model"))
    }

    func testModelListWithoutConfiguredModelReportsInvalidModel() async {
        let data = Data("""
        {"data":[{"id":"available-model"}]}
        """.utf8)
        let probe = RemoteBackendProbe(urlSession: ProbeMockURLSession(
            data: data,
            statusCode: 200,
            expectedPath: "/v1/models"
        ))

        let result = await probe.testConnection(configuration: configuration(model: "missing-model"))

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.issue, .modelNotFound)
        XCTAssertTrue(result.message.contains("model name"))
    }

    func testCompletionProbeDifferentiatesModelRateLimitAndServerFailures() async {
        let cases: [(statusCode: Int, issue: BackendConnectivityIssue, messageFragment: String)] = [
            (404, .httpStatus(404), "endpoint"),
            (429, .rateLimited, "rate-limiting"),
            (500, .httpStatus(500), "HTTP 500")
        ]

        for testCase in cases {
            let probe = RemoteBackendProbe(urlSession: ProbeRoutingURLSession(responses: [
                "/v1/models": (Data(#"{"unexpected":true}"#.utf8), 200),
                "/v1/chat/completions": (Data(#"{"error":{"message":"fixture"}}"#.utf8), testCase.statusCode)
            ]))

            let result = await probe.testConnection(configuration: configuration(model: "test-model"))

            XCTAssertEqual(result.status, .failed, "Status: \(testCase.statusCode)")
            XCTAssertEqual(result.issue, testCase.issue, "Status: \(testCase.statusCode)")
            XCTAssertTrue(result.message.contains(testCase.messageFragment), "Status: \(testCase.statusCode)")
        }
    }

    func testVersionedBaseURLPreservesModelsVersionPrefix() async {
        let data = Data("""
        {"data":[{"id":"local-model"}]}
        """.utf8)
        let probe = RemoteBackendProbe(urlSession: ProbeMockURLSession(
            data: data,
            statusCode: 200,
            expectedPath: "/v2/models"
        ))

        let result = await probe.testConnection(
            configuration: configuration(baseURL: "http://127.0.0.1:8000/v2", model: "local-model")
        )

        XCTAssertEqual(result.status, .connected)
        XCTAssertEqual(result.suggestedModel, "local-model")
    }

    private func configuration(
        baseURL: String = "http://127.0.0.1:8000",
        model: String = "test-model"
    ) -> RemoteCompletionConfiguration {
        RemoteCompletionConfiguration(
            baseURL: baseURL,
            apiKey: "test",
            model: model,
            timeoutSeconds: 0.5
        )
    }
}

private struct ProbeMockURLSession: URLSessionProtocol {
    let data: Data
    let statusCode: Int
    let expectedPath: String

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        XCTAssertEqual(request.url?.path, expectedPath)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test")
        let response = HTTPURLResponse(
            url: try XCTUnwrap(request.url),
            statusCode: statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (data, response)
    }
}

private struct ProbeRoutingURLSession: URLSessionProtocol {
    let responses: [String: (data: Data, statusCode: Int)]

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test")
        guard let url = request.url,
              let fixture = responses[url.path] else {
            XCTFail("Unexpected probe path: \(request.url?.path ?? "nil")")
            throw URLError(.badServerResponse)
        }
        let response = HTTPURLResponse(
            url: url,
            statusCode: fixture.statusCode,
            httpVersion: nil,
            headerFields: nil
        )!
        return (fixture.data, response)
    }
}

private struct ThrowingProbeURLSession: URLSessionProtocol {
    let error: Error

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        throw error
    }
}

private struct FailingIfCalledURLSession: URLSessionProtocol {
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        XCTFail("Probe should not request invalid URLs.")
        throw URLError(.badURL)
    }
}
