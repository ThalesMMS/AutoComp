import AutoCompCore
import XCTest

final class AppleFoundationCompletionProviderTests: XCTestCase {
    func testSystemAvailabilityReportsReadableState() {
        let availability = SystemAppleFoundationModelBackend.availability()

        XCTAssertFalse(availability.statusTitle.isEmpty)
        XCTAssertFalse(availability.detail.isEmpty)
    }

    func testSystemBackendReportsUnavailableOnUnsupportedBuildPath() async throws {
        #if canImport(FoundationModels)
        if #available(macOS 26.0, *) {
            throw XCTSkip("FoundationModels is available on this runtime; generated output is covered by injected backend tests.")
        }
        #endif

        do {
            _ = try await SystemAppleFoundationModelBackend().generate(prompt: "Complete this")
            XCTFail("Expected unavailable system backend")
        } catch let error as AppleFoundationModelError {
            guard case .unavailable(let reason) = error else {
                XCTFail("Expected unavailable error, got \(error)")
                return
            }
            XCTAssertFalse(reason.isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testUnavailableBackendFailsClearly() async {
        let provider = AppleFoundationCompletionProvider(
            backend: FakeAppleFoundationModelBackend(error: AppleFoundationModelError.unavailable("not enabled"))
        )

        do {
            _ = try await provider.complete(context: makeContext())
            XCTFail("Expected unavailable error")
        } catch let error as AppleFoundationModelError {
            XCTAssertEqual(error, .unavailable("not enabled"))
            XCTAssertEqual(error.errorDescription, "Apple Intelligence completion is unavailable: not enabled")
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testGeneratedTextIsNormalizedIntoSuggestion() async throws {
        let provider = AppleFoundationCompletionProvider(
            backend: FakeAppleFoundationModelBackend(rawText: "Completion:\n review this today\nignore")
        )

        let suggestion = try await provider.complete(context: makeContext())

        XCTAssertEqual(suggestion.visibleText, "review this today")
    }

    func testGeneratedFillInMiddleTextIsNormalizedWithSuffix() async throws {
        let provider = AppleFoundationCompletionProvider(
            backend: FakeAppleFoundationModelBackend(
                rawText: "Here is the completion:\nadiada para sexta-feira porque o prazo mudou."
            )
        )

        let suggestion = try await provider.complete(
            context: makeContext(
                textBeforeCursor: "A reuniao foi ",
                textAfterCursor: " porque o prazo mudou."
            )
        )

        XCTAssertEqual(suggestion.visibleText, "adiada para sexta-feira")
    }

    private func makeContext(
        textBeforeCursor: String = "Can you ",
        textAfterCursor: String? = nil
    ) -> TextContext {
        TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: textBeforeCursor,
            textAfterCursor: textAfterCursor
        )
    }
}

private struct FakeAppleFoundationModelBackend: AppleFoundationModelBackend {
    var rawText: String = "review this"
    var error: Error?

    func generate(prompt: String) async throws -> String {
        if let error {
            throw error
        }
        return rawText
    }
}
