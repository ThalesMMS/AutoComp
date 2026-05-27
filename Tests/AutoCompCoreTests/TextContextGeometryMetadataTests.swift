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

    private func context(
        caretGeometryQuality: CaretGeometryQuality,
        observedCharacterWidth: CGFloat?
    ) -> TextContext {
        TextContext(
            id: UUID(uuidString: "D2F50429-A00C-4AB7-89B0-921C7E060452")!,
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: "field",
            stableFieldIdentity: StableFieldIdentity(
                app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
                role: "AXTextArea",
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
            caretGeometryQuality: caretGeometryQuality,
            observedCharacterWidth: observedCharacterWidth,
            createdAt: Date(timeIntervalSince1970: 1_234)
        )
    }
}
