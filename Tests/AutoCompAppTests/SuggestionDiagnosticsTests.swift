import AutoCompCore
@testable import AutoCompApp
import XCTest

final class SuggestionDiagnosticsTests: XCTestCase {
    func testMenuRowsDoNotExposeOutputWhenCollectionIsDisabled() {
        var diagnostics = SuggestionDiagnostics()
        diagnostics.recordBackendSuccess(
            rawText: "secret raw output",
            normalizedText: "secret normalized output",
            collectionAllowed: false
        )

        let rowValues = diagnostics.menuRows.map(\.value)
        XCTAssertFalse(rowValues.contains { $0.contains("secret") })
        XCTAssertEqual(diagnostics.backend.status, .success)
        XCTAssertNil(diagnostics.output.rawPreview)
        XCTAssertNil(diagnostics.output.normalizedPreview)
    }

    func testBackendFailureUsesActionableLocalizedMessage() {
        var diagnostics = SuggestionDiagnostics()

        diagnostics.recordBackendFailure(RemoteCompletionError.connectivity(.timeout))

        XCTAssertEqual(
            diagnostics.backend.lastError,
            "Remote backend timed out. Check that the server is reachable and responding quickly."
        )
        XCTAssertTrue(diagnostics.menuRows.contains {
            $0.title == "Error" && $0.value == diagnostics.backend.lastError
        })
    }
}
