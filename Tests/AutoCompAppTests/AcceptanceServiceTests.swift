import AppKit
import AutoCompCore
@testable import AutoCompApp
import XCTest

@MainActor
final class AcceptanceServiceTests: XCTestCase {
    func testInsertionPolicySelectsStrategyBySizeAppAndFeatureFlag() {
        let policy = AcceptanceInsertionPolicy(
            singleUnicodeFastPathEnabled: true,
            keyboardEventUTF16Limit: 4,
            singleUnicodeIncompatibleBundleIDs: ["com.example.per-character"],
            clipboardPreferredBundleIDs: ["com.example.clipboard"]
        )

        XCTAssertEqual(policy.strategy(for: "hey", bundleID: "com.apple.TextEdit"), .singleUnicodeEvent)
        XCTAssertEqual(policy.strategy(for: "hello", bundleID: "com.apple.TextEdit"), .clipboard)
        XCTAssertEqual(policy.strategy(for: "hey", bundleID: "com.example.per-character"), .perCharacterEvents)
        XCTAssertEqual(policy.strategy(for: "hey", bundleID: "com.example.clipboard"), .clipboard)

        let disabledPolicy = AcceptanceInsertionPolicy(singleUnicodeFastPathEnabled: false)
        XCTAssertEqual(disabledPolicy.strategy(for: "hey", bundleID: "com.apple.TextEdit"), .perCharacterEvents)
    }

    func testUnicodePayloadPreservesAccentsAndEmojiUTF16Units() {
        let text = "cafe\u{301} 🚀"
        let units = AcceptanceUnicodePayload.utf16Units(for: text)

        XCTAssertEqual(String(decoding: units, as: UTF16.self), text)
    }

    func testShortAcceptedTextUsesSingleUnicodeEvent() async throws {
        let poster = RecordingAcceptanceKeyboardEventPoster()
        let service = acceptanceService(keyboardEventPoster: poster)
        var suggestion = Suggestion(
            baseContextID: UUID(),
            visibleText: "cafe\u{301} ",
            latencyMs: 20
        )

        let acceptedText = try await service.acceptNextWord(from: &suggestion)

        XCTAssertEqual(acceptedText, "cafe\u{301} ")
        XCTAssertEqual(poster.unicodeStrings, ["cafe\u{301} "])
        XCTAssertTrue(poster.keyEvents.isEmpty)
    }

    func testShortAcceptedTextRegistersSingleSyntheticPair() async throws {
        let poster = RecordingAcceptanceKeyboardEventPoster()
        let suppressionController = InputSuppressionController()
        let service = acceptanceService(
            keyboardEventPoster: poster,
            inputSuppressionController: suppressionController
        )
        var suggestion = Suggestion(
            baseContextID: UUID(),
            visibleText: "ok ",
            latencyMs: 20
        )

        _ = try await service.acceptNextWord(from: &suggestion)

        try assertSyntheticPairs(
            suppressionController,
            keyCode: 0,
            flags: [],
            count: 1
        )
    }

    func testPerCharacterInsertionRegistersPairPerUTF16Unit() async throws {
        let poster = RecordingAcceptanceKeyboardEventPoster()
        let suppressionController = InputSuppressionController()
        let service = acceptanceService(
            keyboardEventPoster: poster,
            inputSuppressionController: suppressionController,
            insertionPolicy: AcceptanceInsertionPolicy(singleUnicodeFastPathEnabled: false)
        )
        var suggestion = Suggestion(
            baseContextID: UUID(),
            visibleText: "go ",
            latencyMs: 20
        )

        _ = try await service.acceptNextWord(from: &suggestion)

        XCTAssertEqual(poster.unicodeStrings, ["g", "o", " "])
        try assertSyntheticPairs(
            suppressionController,
            keyCode: 0,
            flags: [],
            count: 3
        )
    }

    func testAcceptAllShortTextUsesSingleUnicodeEvent() async throws {
        let poster = RecordingAcceptanceKeyboardEventPoster()
        let service = acceptanceService(keyboardEventPoster: poster)
        var suggestion = Suggestion(
            baseContextID: UUID(),
            visibleText: "finish this",
            latencyMs: 20
        )

        let acceptedText = try await service.acceptAll(from: &suggestion)

        XCTAssertEqual(acceptedText, "finish this")
        XCTAssertEqual(poster.unicodeStrings, ["finish this"])
        XCTAssertTrue(poster.keyEvents.isEmpty)
    }

    func testSingleUnicodeFailureFallsBackToPerCharacterEvents() async throws {
        let poster = RecordingAcceptanceKeyboardEventPoster()
        poster.failMultiUnitUnicode = true
        let service = acceptanceService(keyboardEventPoster: poster)
        var suggestion = Suggestion(
            baseContextID: UUID(),
            visibleText: "go ",
            latencyMs: 20
        )

        let acceptedText = try await service.acceptNextWord(from: &suggestion)

        XCTAssertEqual(acceptedText, "go ")
        XCTAssertEqual(poster.unicodeStrings, ["go ", "g", "o", " "])
        XCTAssertTrue(poster.keyEvents.isEmpty)
    }

    func testLongAcceptedTextUsesClipboardAndRestoresMultiplePasteboardTypes() async throws {
        let poster = RecordingAcceptanceKeyboardEventPoster()
        let pasteboard = RecordingAcceptancePasteboard()
        let suppressionController = InputSuppressionController()
        let customType = NSPasteboard.PasteboardType("com.example.rich-text")
        let originalItems = [
            PreservedPasteboardItem(
                dataByType: [
                    .string: Data("plain".utf8),
                    customType: Data([0x01, 0x02, 0x03])
                ]
            )
        ]
        pasteboard.items = originalItems
        let service = acceptanceService(
            keyboardEventPoster: poster,
            inputSuppressionController: suppressionController,
            pasteboard: pasteboard,
            clipboardRestoreDelay: 0
        )
        let longToken = String(repeating: "a", count: 65) + " "
        var suggestion = Suggestion(
            baseContextID: UUID(),
            visibleText: longToken,
            latencyMs: 20
        )

        let acceptedText = try await service.acceptNextWord(from: &suggestion)

        XCTAssertEqual(acceptedText, longToken)
        XCTAssertTrue(poster.unicodeStrings.isEmpty)
        XCTAssertEqual(poster.keyEvents.count, 1)
        XCTAssertEqual(poster.keyEvents.first?.keyCode, 0x09)
        XCTAssertEqual(poster.keyEvents.first?.flags, .maskCommand)
        XCTAssertEqual(pasteboard.setStrings, [longToken])
        XCTAssertEqual(pasteboard.items, originalItems)
        try assertSyntheticPairs(
            suppressionController,
            keyCode: 0x09,
            flags: .maskCommand,
            count: 1
        )
    }

    private func acceptanceService(
        keyboardEventPoster: RecordingAcceptanceKeyboardEventPoster,
        inputSuppressionController: InputSuppressionController? = nil,
        pasteboard: RecordingAcceptancePasteboard = RecordingAcceptancePasteboard(),
        insertionPolicy: AcceptanceInsertionPolicy = AcceptanceInsertionPolicy(),
        clipboardRestoreDelay: TimeInterval = 0.2
    ) -> AcceptanceService {
        AcceptanceService(
            inputSuppressionController: inputSuppressionController,
            insertionPolicy: insertionPolicy,
            keyboardEventPoster: keyboardEventPoster,
            pasteboard: pasteboard,
            frontmostBundleIDProvider: { "com.apple.TextEdit" },
            clipboardRestoreDelay: clipboardRestoreDelay
        )
    }

    private func assertSyntheticPairs(
        _ controller: InputSuppressionController,
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        count: Int
    ) throws {
        for _ in 0..<count {
            let keyDown = try makeKeyboardEvent(keyCode: keyCode, flags: flags, keyDown: true)
            XCTAssertTrue(controller.consumeIfSynthetic(event: keyDown))
        }

        let extraKeyDown = try makeKeyboardEvent(keyCode: keyCode, flags: flags, keyDown: true)
        XCTAssertFalse(controller.consumeIfSynthetic(event: extraKeyDown))

        for _ in 0..<count {
            let keyUp = try makeKeyboardEvent(keyCode: keyCode, flags: flags, keyDown: false)
            XCTAssertTrue(controller.consumeIfSynthetic(event: keyUp))
        }

        let extraKeyUp = try makeKeyboardEvent(keyCode: keyCode, flags: flags, keyDown: false)
        XCTAssertFalse(controller.consumeIfSynthetic(event: extraKeyUp))
    }

    private func makeKeyboardEvent(
        keyCode: CGKeyCode,
        flags: CGEventFlags,
        keyDown: Bool
    ) throws -> CGEvent {
        let event = try XCTUnwrap(CGEvent(keyboardEventSource: nil, virtualKey: keyCode, keyDown: keyDown))
        event.flags = flags
        return event
    }
}

private final class RecordingAcceptanceKeyboardEventPoster: AcceptanceKeyboardEventPosting {
    struct KeyEvent: Equatable {
        let keyCode: CGKeyCode
        let flags: CGEventFlags
    }

    var failMultiUnitUnicode = false
    private(set) var unicodeStrings: [String] = []
    private(set) var keyEvents: [KeyEvent] = []

    func postUnicodeString(_ units: [UniChar]) -> Bool {
        unicodeStrings.append(String(decoding: units, as: UTF16.self))
        if failMultiUnitUnicode, units.count > 1 {
            return false
        }
        return true
    }

    func postKey(_ keyCode: CGKeyCode, flags: CGEventFlags) -> Bool {
        keyEvents.append(KeyEvent(keyCode: keyCode, flags: flags))
        return true
    }
}

private final class RecordingAcceptancePasteboard: AcceptancePasteboard {
    var items: [PreservedPasteboardItem]?
    private(set) var setStrings: [String] = []

    func preservedItems() -> [PreservedPasteboardItem]? {
        items
    }

    func clearContents() {
        items = []
    }

    func setString(_ text: String) {
        setStrings.append(text)
        items = [
            PreservedPasteboardItem(dataByType: [.string: Data(text.utf8)])
        ]
    }

    func writeItems(_ items: [PreservedPasteboardItem]) {
        self.items = items
    }
}
