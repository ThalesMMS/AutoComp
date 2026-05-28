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
        let recoveryStore = try makePasteboardRecoveryStore()
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
            pasteboardRecoveryStore: recoveryStore,
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
        XCTAssertFalse(recoveryStore.hasPendingSnapshot())
        try assertSyntheticPairs(
            suppressionController,
            keyCode: 0x09,
            flags: .maskCommand,
            count: 1
        )
    }

    func testPasteboardRecoveryRestoresMarkedSnapshotAfterRestart() throws {
        let pasteboard = RecordingAcceptancePasteboard()
        let recoveryStore = try makePasteboardRecoveryStore()
        let customType = NSPasteboard.PasteboardType("com.example.rich-text")
        let originalItems = [
            PreservedPasteboardItem(dataByType: [
                .string: Data("original rich value".utf8),
                customType: Data([0x01, 0x02, 0x03])
            ])
        ]
        try recoveryStore.save(PasteboardInsertionRecoverySnapshot(
            id: "recovery-id",
            createdAt: Date(),
            previousItems: originalItems
        ))
        pasteboard.items = [
            PreservedPasteboardItem(dataByType: [.string: Data("temporary insertion".utf8)])
        ]
        pasteboard.activeRecoveryMarkerID = "recovery-id"
        let service = acceptanceService(
            keyboardEventPoster: RecordingAcceptanceKeyboardEventPoster(),
            pasteboard: pasteboard,
            pasteboardRecoveryStore: recoveryStore
        )

        service.recoverPendingPasteboardInsertionIfNeeded()

        XCTAssertEqual(pasteboard.items, originalItems)
        XCTAssertNil(pasteboard.activeRecoveryMarkerID)
        XCTAssertFalse(recoveryStore.hasPendingSnapshot())
    }

    func testPasteboardRecoveryDeletesSnapshotWhenMarkerIsMissing() throws {
        let pasteboard = RecordingAcceptancePasteboard()
        let recoveryStore = try makePasteboardRecoveryStore()
        let userChangedItems = [
            PreservedPasteboardItem(dataByType: [.string: Data("new user pasteboard".utf8)])
        ]
        try recoveryStore.save(PasteboardInsertionRecoverySnapshot(
            id: "stale-id",
            createdAt: Date(),
            previousItems: [
                PreservedPasteboardItem(dataByType: [.string: Data("old secret".utf8)])
            ]
        ))
        pasteboard.items = userChangedItems
        pasteboard.activeRecoveryMarkerID = nil
        let service = acceptanceService(
            keyboardEventPoster: RecordingAcceptanceKeyboardEventPoster(),
            pasteboard: pasteboard,
            pasteboardRecoveryStore: recoveryStore
        )

        service.recoverPendingPasteboardInsertionIfNeeded()

        XCTAssertEqual(pasteboard.items, userChangedItems)
        XCTAssertFalse(recoveryStore.hasPendingSnapshot())
    }

    func testPasteboardRecoveryDeletesExpiredSnapshotWithoutRestoringSensitiveMaterial() throws {
        let pasteboard = RecordingAcceptancePasteboard()
        let now = Date(timeIntervalSince1970: 1_000)
        let recoveryStore = try makePasteboardRecoveryStore(
            recoveryWindow: 30,
            now: { now }
        )
        let currentItems = [
            PreservedPasteboardItem(dataByType: [.string: Data("current pasteboard".utf8)])
        ]
        try recoveryStore.save(PasteboardInsertionRecoverySnapshot(
            id: "expired-id",
            createdAt: now.addingTimeInterval(-31),
            previousItems: [
                PreservedPasteboardItem(dataByType: [.string: Data("expired secret".utf8)])
            ]
        ))
        pasteboard.items = currentItems
        pasteboard.activeRecoveryMarkerID = "expired-id"
        let service = acceptanceService(
            keyboardEventPoster: RecordingAcceptanceKeyboardEventPoster(),
            pasteboard: pasteboard,
            pasteboardRecoveryStore: recoveryStore
        )

        service.recoverPendingPasteboardInsertionIfNeeded()

        XCTAssertEqual(pasteboard.items, currentItems)
        XCTAssertEqual(pasteboard.activeRecoveryMarkerID, "expired-id")
        XCTAssertFalse(recoveryStore.hasPendingSnapshot())
    }

    func testChatAppInsertionRejectsReturnTextBeforePostingEvents() async throws {
        let poster = RecordingAcceptanceKeyboardEventPoster()
        let pasteboard = RecordingAcceptancePasteboard()
        let service = acceptanceService(
            keyboardEventPoster: poster,
            pasteboard: pasteboard,
            frontmostBundleID: "com.tinyspeck.slackmacgap"
        )
        var suggestion = Suggestion(
            baseContextID: UUID(),
            visibleText: "line one\nline two",
            latencyMs: 20
        )

        do {
            _ = try await service.acceptAll(from: &suggestion)
            XCTFail("Expected chat Return insertion to be blocked")
        } catch AcceptanceError.riskyHostReturnBlocked {
            XCTAssertTrue(poster.unicodeStrings.isEmpty)
            XCTAssertTrue(poster.keyEvents.isEmpty)
            XCTAssertTrue(pasteboard.setStrings.isEmpty)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    private func acceptanceService(
        keyboardEventPoster: RecordingAcceptanceKeyboardEventPoster,
        inputSuppressionController: InputSuppressionController? = nil,
        pasteboard: RecordingAcceptancePasteboard = RecordingAcceptancePasteboard(),
        pasteboardRecoveryStore: PasteboardInsertionRecoveryStore? = nil,
        insertionPolicy: AcceptanceInsertionPolicy = AcceptanceInsertionPolicy(),
        clipboardRestoreDelay: TimeInterval = 0.2,
        frontmostBundleID: String = "com.apple.TextEdit"
    ) -> AcceptanceService {
        AcceptanceService(
            inputSuppressionController: inputSuppressionController,
            insertionPolicy: insertionPolicy,
            keyboardEventPoster: keyboardEventPoster,
            pasteboard: pasteboard,
            pasteboardRecoveryStore: pasteboardRecoveryStore,
            frontmostBundleIDProvider: { frontmostBundleID },
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

    private func makePasteboardRecoveryStore(
        recoveryWindow: TimeInterval = 5 * 60,
        now: @escaping () -> Date = { Date() }
    ) throws -> PasteboardInsertionRecoveryStore {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("autocomp-pasteboard-recovery-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: directory)
        }
        return PasteboardInsertionRecoveryStore(
            directory: directory,
            recoveryWindow: recoveryWindow,
            now: now
        )
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
    var activeRecoveryMarkerID: String?
    private(set) var setStrings: [String] = []

    func preservedItems() -> [PreservedPasteboardItem]? {
        items
    }

    func clearContents() {
        items = []
        activeRecoveryMarkerID = nil
    }

    func setString(_ text: String, recoveryMarkerID: String?) {
        setStrings.append(text)
        activeRecoveryMarkerID = recoveryMarkerID
        items = [
            PreservedPasteboardItem(dataByType: [.string: Data(text.utf8)])
        ]
    }

    func writeItems(_ items: [PreservedPasteboardItem]) {
        self.items = items
        activeRecoveryMarkerID = nil
    }

    func containsRecoveryMarker(id: String) -> Bool {
        activeRecoveryMarkerID == id
    }
}
