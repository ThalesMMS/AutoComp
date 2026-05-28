@testable import AutoCompApp
import XCTest

final class PromptBudgetDocumentationTests: XCTestCase {
    func testPromptBudgetsDocumentedForEachModeAndSource() throws {
        let document = try String(
            contentsOf: try packageRoot().appendingPathComponent("Docs/PromptBudgets.md"),
            encoding: .utf8
        )

        for requiredText in [
            "Continuation primary prefix",
            "`continuationPrefixCharacters`",
            "1,500 characters",
            "FIM primary prefix",
            "`fimPrefixCharacters`",
            "1,200 characters",
            "FIM suffix",
            "`fimSuffixCharacters`",
            "700 characters",
            "Active selection",
            "`selectionCharacters`",
            "500 characters",
            "Clipboard context",
            "`clipboardCharacters`",
            "Visual context",
            "`visualContextCharacters`",
            "Prompt echo-removal candidates must match the text actually injected into the prompt",
            "shows only sizes and counts"
        ] {
            XCTAssertTrue(document.contains(requiredText), "Missing prompt budget text: \(requiredText)")
        }
    }

    func testBackendStopSequencesDocumentProviderBehaviorAndFallback() throws {
        let document = try String(
            contentsOf: try packageRoot().appendingPathComponent("Docs/BackendStopSequences.md"),
            encoding: .utf8
        )

        for requiredText in [
            "Remote OpenAI-compatible requests send the active mode's stop list as the `stop` request parameter.",
            "Local Llama requests pass the active mode's stop list into the llama.cpp generation loop",
            "Apple Intelligence does not expose generation stop sequences",
            "post-generation trimming fallback",
            "AUTOCOMP_STOP_SEQUENCES_CONTINUATION",
            "AUTOCOMP_STOP_SEQUENCES_FIM",
            "Newline stops are supported",
            "not enabled by default"
        ] {
            XCTAssertTrue(document.contains(requiredText), "Missing stop sequence text: \(requiredText)")
        }
    }

    private func packageRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath)
        while url.pathComponents.count > 1 {
            url.deleteLastPathComponent()
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
        }
        throw NSError(domain: "PromptBudgetDocumentationTests", code: 1)
    }
}
