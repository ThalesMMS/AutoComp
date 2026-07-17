import AutoCompCore
@testable import AutoCompApp
import XCTest

@MainActor
final class EmojiPickerControllerTests: XCTestCase {
    func testTriggerStateMachineActivatesOnlyAtBoundaryAndMeasuresUTF16() {
        var state = EmojiTriggerStateMachine()

        XCTAssertNil(state.update(textBeforeCursor: "email:smile"))

        let openRun = state.update(textBeforeCursor: "hello :smile")
        XCTAssertEqual(openRun?.query, "smile")
        XCTAssertEqual(openRun?.replacementUTF16Length, 6)
        XCTAssertEqual(openRun?.hasClosingColon, false)

        let reducedRun = state.update(textBeforeCursor: "hello :smil")
        XCTAssertEqual(reducedRun?.query, "smil")
        XCTAssertEqual(reducedRun?.replacementUTF16Length, 5)

        let closedRun = state.update(textBeforeCursor: "hello :smile:")
        XCTAssertEqual(closedRun?.query, "smile")
        XCTAssertEqual(closedRun?.replacementUTF16Length, 7)
        XCTAssertEqual(closedRun?.hasClosingColon, true)
    }

    func testMatcherRanksExactAliasesPrefixesAndKeywords() {
        let matcher = EmojiMatcher()

        XCTAssertEqual(matcher.matches(for: "smile").first?.entry.primaryAlias, "smile")
        XCTAssertEqual(matcher.matches(for: "smi").first?.entry.primaryAlias, "smile")
        XCTAssertEqual(matcher.matches(for: "launch").first?.entry.primaryAlias, "rocket")
        XCTAssertEqual(matcher.exactMatch(for: ":smile:")?.entry.glyph, "😄")
    }

    func testMatcherQueryTrimsColonsWithoutChangingCatalogAliases() {
        let colonAlias = EmojiCatalogEntry(aliases: [":ship it:"], glyph: "🛳")
        XCTAssertEqual(colonAlias.primaryAlias, ":ship_it:")
        XCTAssertNil(EmojiMatcher(entries: [colonAlias]).exactMatch(for: ":ship it:"))

        let plainAlias = EmojiCatalogEntry(aliases: ["ship it"], glyph: "🚢")
        let matcher = EmojiMatcher(entries: [plainAlias])

        XCTAssertEqual(matcher.exactMatch(for: ":ship it:")?.entry.glyph, "🚢")
        XCTAssertEqual(matcher.matches(for: " ship it ").first?.entry.glyph, "🚢")
    }

    func testControllerShowsPanelAndCommitsSelectedEmoji() async {
        let contextProvider = FakeEmojiTextContextProvider(context: textContext("hello :smile"))
        let replacer = RecordingEmojiTextReplacer()
        let panel = RecordingEmojiPickerPanelController()
        let controller = EmojiPickerController(
            contextProvider: contextProvider,
            textReplacer: replacer,
            panelController: panel,
            hostPublishAwaiter: HostPublishAwaiter(configuration: .init(
                firstReadDelayNanoseconds: 0,
                pollIntervalNanoseconds: 0,
                timeoutNanoseconds: 0
            )),
            hostPublishDelayNanoseconds: 0
        )
        var activeStates: [Bool] = []
        controller.onActiveChanged = { activeStates.append($0) }

        let handled = await controller.handleInputEvent(.text(keyCode: 0, isSuggestionTrigger: false))

        XCTAssertTrue(handled)
        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(controller.activeQuery, "smile")
        XCTAssertEqual(panel.showCalls.count, 1)
        XCTAssertEqual(panel.showCalls.first?.matches.first?.entry.primaryAlias, "smile")
        XCTAssertEqual(activeStates, [true])

        await controller.handleKeyboardCommand(.acceptSelected)

        XCTAssertEqual(replacer.replacements, [
            RecordingEmojiTextReplacer.Replacement(utf16Length: 6, text: "😄")
        ])
        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(activeStates, [true, false])
    }

    func testClosedAliasAutoCommitsExactMatch() async {
        let contextProvider = FakeEmojiTextContextProvider(context: textContext("hello :thumbsup:"))
        let replacer = RecordingEmojiTextReplacer()
        let panel = RecordingEmojiPickerPanelController()
        let preferences = EmojiVariantPreferences(skinTone: .medium)
        let store = EmojiVariantPreferencesStore(defaults: suiteDefaults(), key: "emoji")
        try? store.save(preferences)
        let controller = EmojiPickerController(
            contextProvider: contextProvider,
            textReplacer: replacer,
            preferencesStore: store,
            panelController: panel,
            hostPublishDelayNanoseconds: 0
        )

        let handled = await controller.handleInputEvent(.text(keyCode: 0, isSuggestionTrigger: false))

        XCTAssertTrue(handled)
        XCTAssertEqual(replacer.replacements, [
            RecordingEmojiTextReplacer.Replacement(utf16Length: 10, text: "👍🏽")
        ])
        XCTAssertFalse(controller.isActive)
        XCTAssertTrue(panel.showCalls.isEmpty)
    }

    func testEscapeCancelsActivePicker() async {
        let contextProvider = FakeEmojiTextContextProvider(context: textContext("hello :smile"))
        let replacer = RecordingEmojiTextReplacer()
        let panel = RecordingEmojiPickerPanelController()
        let controller = EmojiPickerController(
            contextProvider: contextProvider,
            textReplacer: replacer,
            panelController: panel,
            hostPublishAwaiter: HostPublishAwaiter(configuration: .init(
                firstReadDelayNanoseconds: 0,
                pollIntervalNanoseconds: 0,
                timeoutNanoseconds: 0
            )),
            hostPublishDelayNanoseconds: 0
        )

        _ = await controller.handleInputEvent(.text(keyCode: 0, isSuggestionTrigger: false))
        await controller.handleKeyboardCommand(.cancel)

        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(panel.hideCount, 1)
        XCTAssertTrue(replacer.replacements.isEmpty)
    }

    func testFocusChangeCancelsActivePicker() async {
        let originalContext = textContext("hello :smile", focusSequence: 1)
        let changedContext = textContext("hello :smil", focusSequence: 2)
        let contextProvider = FakeEmojiTextContextProvider(context: originalContext)
        let panel = RecordingEmojiPickerPanelController()
        let controller = EmojiPickerController(
            contextProvider: contextProvider,
            textReplacer: RecordingEmojiTextReplacer(),
            panelController: panel,
            hostPublishDelayNanoseconds: 0
        )

        _ = await controller.handleInputEvent(.text(keyCode: 0, isSuggestionTrigger: false))
        contextProvider.context = changedContext
        let handled = await controller.handleInputEvent(.text(keyCode: 0, isSuggestionTrigger: false))

        XCTAssertTrue(handled)
        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(panel.hideCount, 1)
    }

    func testPanelSelectionCommitsClickedItem() async {
        let contextProvider = FakeEmojiTextContextProvider(context: textContext("hello :rocket"))
        let replacer = RecordingEmojiTextReplacer()
        let panel = RecordingEmojiPickerPanelController()
        let controller = EmojiPickerController(
            contextProvider: contextProvider,
            textReplacer: replacer,
            panelController: panel,
            hostPublishAwaiter: HostPublishAwaiter(configuration: .init(
                firstReadDelayNanoseconds: 0,
                pollIntervalNanoseconds: 0,
                timeoutNanoseconds: 0
            )),
            hostPublishDelayNanoseconds: 0
        )
        let committed = expectation(description: "Clicked emoji committed")
        controller.onActiveChanged = { isActive in
            if !isActive {
                committed.fulfill()
            }
        }

        _ = await controller.handleInputEvent(.text(keyCode: 0, isSuggestionTrigger: false))
        panel.select(index: 0)
        await fulfillment(of: [committed], timeout: 1)

        XCTAssertEqual(replacer.replacements, [
            RecordingEmojiTextReplacer.Replacement(utf16Length: 7, text: "🚀")
        ])
        XCTAssertFalse(controller.isActive)
    }

    func testSecureOrUnreadableContextDoesNotOpenPicker() async {
        let contextProvider = FakeEmojiTextContextProvider(error: AXTextContextError.secureOrUnsupportedField)
        let controller = EmojiPickerController(
            contextProvider: contextProvider,
            textReplacer: RecordingEmojiTextReplacer(),
            panelController: RecordingEmojiPickerPanelController(),
            hostPublishDelayNanoseconds: 0
        )

        let handled = await controller.handleInputEvent(.text(keyCode: 0, isSuggestionTrigger: false))

        XCTAssertFalse(handled)
        XCTAssertFalse(controller.isActive)
    }

    private func textContext(_ textBeforeCursor: String, focusSequence: UInt64 = 1) -> TextContext {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        return TextContext(
            app: app,
            focusedElementID: "field",
            stableFieldIdentity: StableFieldIdentity(
                app: app,
                role: "AXTextArea",
                focusedElementFrame: CGRect(x: 10, y: 10, width: 400, height: 200),
                focusChangeSequence: focusSequence
            ),
            textBeforeCursor: textBeforeCursor,
            selectedRange: NSRange(location: textBeforeCursor.utf16.count, length: 0),
            caretRect: CGRect(x: 20, y: 20, width: 2, height: 18),
            focusedElementRect: CGRect(x: 10, y: 10, width: 400, height: 200)
        )
    }

    private func suiteDefaults() -> UserDefaults {
        let suiteName = "EmojiPickerControllerTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }
}

private final class FakeEmojiTextContextProvider: TextContextProvider, @unchecked Sendable {
    var context: TextContext?
    var error: Error?

    init(context: TextContext? = nil, error: Error? = nil) {
        self.context = context
        self.error = error
    }

    func currentContext() async throws -> TextContext {
        if let error {
            throw error
        }
        guard let context else {
            throw AXTextContextError.noReadableText
        }
        return context
    }
}

@MainActor
private final class RecordingEmojiTextReplacer: EmojiTextReplacing {
    struct Replacement: Equatable {
        let utf16Length: Int
        let text: String
    }

    private(set) var replacements: [Replacement] = []

    func replaceTrailingText(utf16Length: Int, with text: String) throws {
        replacements.append(Replacement(utf16Length: utf16Length, text: text))
    }
}

@MainActor
private final class RecordingEmojiPickerPanelController: EmojiPickerPanelControlling {
    struct ShowCall {
        let matches: [EmojiMatch]
        let selectedIndex: Int
    }

    private(set) var showCalls: [ShowCall] = []
    private(set) var hideCount = 0
    private var onSelect: ((Int) -> Void)?

    func show(
        matches: [EmojiMatch],
        selectedIndex: Int,
        preferences: EmojiVariantPreferences,
        anchorContext: TextContext,
        onSelect: @escaping (Int) -> Void
    ) {
        showCalls.append(ShowCall(matches: matches, selectedIndex: selectedIndex))
        self.onSelect = onSelect
    }

    func hide() {
        hideCount += 1
    }

    func select(index: Int) {
        onSelect?(index)
    }
}
