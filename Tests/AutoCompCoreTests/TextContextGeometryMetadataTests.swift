import AutoCompCore
import CoreGraphics
import XCTest

final class TextContextGeometryMetadataTests: XCTestCase {
    func testGeometryMetadataParticipatesInEquality() {
        let base = context(
            caretGeometryQuality: .directCaret,
            observedCharacterWidth: 7
        )
        let differentQuality = context(
            caretGeometryQuality: .glyph,
            observedCharacterWidth: 7
        )
        let differentWidth = context(
            caretGeometryQuality: .directCaret,
            observedCharacterWidth: 8
        )

        XCTAssertNotEqual(base, differentQuality)
        XCTAssertNotEqual(base, differentWidth)
    }

    func testGeometryMetadataRoundTripsThroughCodable() throws {
        let original = context(
            caretGeometryQuality: .lineMetric,
            observedCharacterWidth: 9
        )

        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(TextContext.self, from: data)

        XCTAssertEqual(decoded, original)
        XCTAssertEqual(decoded.caretGeometryQuality, .lineMetric)
        XCTAssertEqual(decoded.observedCharacterWidth, 9)
        XCTAssertEqual(decoded.textAfterCursor, " after")
        XCTAssertEqual(decoded.selectedText, "selected")
        XCTAssertEqual(decoded.fullTextWindow, "Hello selected after")
        XCTAssertEqual(decoded.stableFieldIdentity?.roundedFocusedElementFrame, CGRect(x: 80, y: 10, width: 300, height: 40))
        XCTAssertEqual(decoded.stableFieldIdentity?.focusChangeSequence, 2)
    }

    func testCopyPreservesAllFieldsExceptExplicitOverrides() {
        let original = context(
            caretGeometryQuality: .lineMetric,
            observedCharacterWidth: 9
        )
        let replacementIdentity = StableFieldIdentity(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            domain: "notes.example",
            role: "AXTextField",
            subrole: "AXSearchField",
            focusedElementFrame: CGRect(x: 40, y: 20, width: 250, height: 22),
            focusChangeSequence: 99
        )

        let copied = original.copy(
            textBeforeCursor: "Updated",
            stableFieldIdentity: replacementIdentity
        )

        XCTAssertEqual(copied, TextContext(
            id: original.id,
            app: original.app,
            domain: original.domain,
            focusedElementID: original.focusedElementID,
            stableFieldIdentity: replacementIdentity,
            textBeforeCursor: "Updated",
            textAfterCursor: original.textAfterCursor,
            selectedText: original.selectedText,
            fullTextWindow: original.fullTextWindow,
            selectedRange: original.selectedRange,
            caretRect: original.caretRect,
            focusedElementRect: original.focusedElementRect,
            previousGlyphRect: original.previousGlyphRect,
            nextGlyphRect: original.nextGlyphRect,
            lineReferenceRect: original.lineReferenceRect,
            caretGeometryQuality: original.caretGeometryQuality,
            observedCharacterWidth: original.observedCharacterWidth,
            languageHint: original.languageHint,
            captureSources: original.captureSources,
            createdAt: original.createdAt
        ))
    }

    func testCopyCanClearStableFieldIdentity() {
        let original = context(
            caretGeometryQuality: .directCaret,
            observedCharacterWidth: 7
        )

        let copied = original.copy(stableFieldIdentity: .some(nil))

        XCTAssertNil(copied.stableFieldIdentity)
        XCTAssertEqual(copied.textBeforeCursor, original.textBeforeCursor)
        XCTAssertEqual(copied.textAfterCursor, original.textAfterCursor)
        XCTAssertEqual(copied.captureSources, original.captureSources)
    }

    func testLegacyTextContextCopyHelpersDelegateToCentralCopy() throws {
        for relativePath in [
            "Sources/AutoCompCore/Support/SuggestionRefreshDecision.swift",
            "Sources/AutoCompApp/Services/AcceptanceSessionController.swift",
            "Sources/AutoCompApp/Services/FocusTrackingModel.swift",
            "Tests/AutoCompCoreTests/SuggestionRefreshDecisionTests.swift"
        ] {
            let source = try sourceFile(relativePath)
            XCTAssertTrue(source.contains(".copy("), "Expected \(relativePath) to delegate TextContext copying to TextContext.copy")
            XCTAssertFalse(source.contains("TextContext(\n            id: id,"), "Remove full-field TextContext copy from \(relativePath)")
        }
    }

    private func context(
        caretGeometryQuality: CaretGeometryQuality,
        observedCharacterWidth: CGFloat?
    ) -> TextContext {
        TextContext(
            id: UUID(uuidString: "D2F50429-A00C-4AB7-89B0-921C7E060452")!,
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            domain: "docs.example",
            focusedElementID: "field",
            stableFieldIdentity: StableFieldIdentity(
                app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
                domain: "docs.example",
                role: "AXTextArea",
                subrole: "AXDocument",
                focusedElementFrame: CGRect(x: 80.2, y: 10.4, width: 300.1, height: 40.3),
                focusChangeSequence: 2
            ),
            textBeforeCursor: "Hello",
            textAfterCursor: " after",
            selectedText: "selected",
            fullTextWindow: "Hello selected after",
            selectedRange: NSRange(location: 5, length: 0),
            caretRect: CGRect(x: 100, y: 20, width: 2, height: 20),
            focusedElementRect: CGRect(x: 80, y: 10, width: 300, height: 40),
            previousGlyphRect: CGRect(x: 92, y: 20, width: 7, height: 20),
            nextGlyphRect: CGRect(x: 108, y: 20, width: 8, height: 20),
            lineReferenceRect: CGRect(x: 80, y: 20, width: 260, height: 20),
            caretGeometryQuality: caretGeometryQuality,
            observedCharacterWidth: observedCharacterWidth,
            languageHint: "en-US",
            captureSources: [.accessibility, .screenOCR],
            createdAt: Date(timeIntervalSince1970: 1_234)
        )
    }

}
