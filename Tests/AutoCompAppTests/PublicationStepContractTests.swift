import XCTest

final class PublicationStepContractTests: XCTestCase {
    func testPublicationStepDocumentsSuggestionContextPrecondition() throws {
        let source = try String(
            contentsOf: try packageRoot().appendingPathComponent("Sources/AutoCompApp/Services/PublicationStep.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(source.contains("Precondition:"))
        XCTAssertTrue(source.contains("context.suggestion"))
        XCTAssertTrue(source.contains("ProviderInvocationStep"))
        XCTAssertTrue(source.contains("missing-suggestion"))
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
