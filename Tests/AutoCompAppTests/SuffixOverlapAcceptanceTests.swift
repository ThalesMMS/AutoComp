import AutoCompCore
@testable import AutoCompApp
import XCTest

@MainActor
final class SuffixOverlapAcceptanceTests: XCTestCase {
    func testAcceptNextWordAdvancesWhenSuffixOverlapConsumesEntireToken() async throws {
        let controller = SuggestionAcceptanceController(sessionController: AcceptanceSessionController())
        let inserter = RecordingTextInserter()
        let context = TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 123),
            domain: nil,
            focusedElementID: "field",
            stableFieldIdentity: nil,
            textBeforeCursor: "",
            textAfterCursor: "world",
            selectedText: nil,
            fullTextWindow: nil,
            selectedRange: nil,
            caretRect: nil,
            focusedElementRect: nil,
            caretGeometryQuality: .unavailable,
            captureSources: [.accessibility]
        )
        let suggestion = Suggestion(baseContextID: context.id, visibleText: "world", latencyMs: 0)

        let result = try await controller.acceptNextWord(
            currentSuggestion: suggestion,
            currentContext: context,
            using: inserter
        )

        XCTAssertEqual(result?.acceptedText, "")
        XCTAssertNil(result?.currentSuggestion)
        XCTAssertTrue(result?.completedAcceptAllStateArmed ?? false)
        XCTAssertEqual(inserter.insertedTexts, [])
    }

    func testAcceptAllTrimsExactSuffixOverlapBeforeInsertion() async throws {
        final class RecordingPoster: AcceptanceKeyboardEventPosting {
            var unicodeStrings: [String] = []
            func postUnicodeString(_ units: [UniChar]) -> Bool {
                unicodeStrings.append(String(decoding: units, as: UTF16.self))
                return true
            }
            func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) -> Bool { true }
        }

        final class RecordingPasteboard: AcceptancePasteboard {
            func preservedItems() -> [PreservedPasteboardItem]? { [] }
            func clearContents() {}
            func setString(_ text: String, recoveryMarkerID: String?) {}
            func writeItems(_ items: [PreservedPasteboardItem]) {}
            func containsRecoveryMarker(id: String) -> Bool { false }
            func currentRecoveryMarkerID() -> String? { nil }
        }

        let poster = RecordingPoster()
        let service = AcceptanceService(
            insertionPolicy: AcceptanceInsertionPolicy(singleUnicodeFastPathEnabled: true),
            keyboardEventPoster: poster,
            pasteboard: RecordingPasteboard(),
            pasteboardRecoveryStore: nil,
            frontmostBundleIDProvider: { "com.apple.TextEdit" },
            clipboardRestoreDelay: 0
        )

        let controller = SuggestionAcceptanceController(sessionController: AcceptanceSessionController())

        let context = TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 123),
            domain: nil,
            focusedElementID: "field",
            stableFieldIdentity: nil,
            textBeforeCursor: "Hello",
            textAfterCursor: " world",
            selectedText: nil,
            fullTextWindow: nil,
            selectedRange: nil,
            caretRect: nil,
            focusedElementRect: nil,
            caretGeometryQuality: .unavailable,
            captureSources: [.accessibility]
        )

        let suggestion = Suggestion(baseContextID: context.id, visibleText: "Hello world", latencyMs: 0)
        let result = try await controller.acceptAll(
            currentSuggestion: suggestion,
            currentContext: context,
            using: service
        )

        XCTAssertEqual(result?.acceptedText, "Hello")
        XCTAssertEqual(poster.unicodeStrings, ["Hello"])
    }
}

@MainActor
private final class RecordingTextInserter: TextInserter {
    private(set) var insertedTexts: [String] = []

    func insert(_ text: String) throws {
        insertedTexts.append(text)
    }

    func acceptNextWord(from suggestion: inout Suggestion) async throws -> String? {
        guard let token = suggestion.acceptNextWord() else {
            return nil
        }
        try insert(token)
        return token
    }

    func acceptAll(from suggestion: inout Suggestion) async throws -> String? {
        guard let token = suggestion.acceptAll() else {
            return nil
        }
        try insert(token)
        return token
    }
}
