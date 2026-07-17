import AutoCompCore
@testable import AutoCompApp
import XCTest

@MainActor
final class MacroCommandControllerTests: XCTestCase {
    func testTriggerRequiresBoundaryAndMeasuresLiteralAfterUnicodeContext() {
        XCTAssertNil(MacroTriggerStateMachine.queryRun(in: "prefix;;2+2"))

        let emptyRun = MacroTriggerStateMachine.queryRun(in: "prefix ;;")
        XCTAssertEqual(emptyRun?.query, "")
        XCTAssertEqual(emptyRun?.literal, ";;")

        let run = MacroTriggerStateMachine.queryRun(in: "😀 ação ;;2+2")
        XCTAssertEqual(run?.query, "2+2")
        XCTAssertEqual(run?.literal, ";;2+2")
        XCTAssertEqual(run?.literal.utf16.count, 5)

        let conversion = MacroTriggerStateMachine.queryRun(in: "value ;;10km->mi")
        XCTAssertEqual(conversion?.query, "10km->mi")
        XCTAssertEqual(conversion?.literal, ";;10km->mi")
    }

    func testControllerPreviewsAndCommitsAfterRevalidatingLiteral() async {
        let contextProvider = MutableMacroContextProvider(context: textContext("😀 ação ;;2+2"))
        let replacer = RecordingMacroTextReplacer {
            contextProvider.context = self.textContext("😀 ação 4")
        }
        let panel = RecordingMacroPanel()
        let controller = makeController(contextProvider: contextProvider, replacer: replacer, panel: panel)

        let handled = await controller.handleInputEvent(.text(keyCode: 0, isSuggestionTrigger: false))
        XCTAssertTrue(handled)
        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(panel.values.last?.preview, "= 4")
        XCTAssertEqual(controller.keyboardCapabilities, .singleResult)

        await controller.handleKeyboardCommand(.acceptSelected)

        XCTAssertEqual(replacer.replacements, [.init(utf16Length: 5, text: "4")])
        XCTAssertFalse(controller.isActive)
    }

    func testCommitFailsClosedWhenRunChangedOrFocusChanged() async {
        let contextProvider = MutableMacroContextProvider(context: textContext("hello ;;2+2"))
        let replacer = RecordingMacroTextReplacer()
        let controller = makeController(contextProvider: contextProvider, replacer: replacer)
        _ = await controller.handleInputEvent(.text(keyCode: 0, isSuggestionTrigger: false))

        contextProvider.context = textContext("hello ;;9+9")
        await controller.handleKeyboardCommand(.acceptSelected)

        XCTAssertTrue(replacer.replacements.isEmpty)
        XCTAssertFalse(controller.isActive)

        contextProvider.context = textContext("hello ;;2+2", focusSequence: 1)
        _ = await controller.handleInputEvent(.text(keyCode: 0, isSuggestionTrigger: false))
        contextProvider.context = textContext("hello ;;2+2", focusSequence: 2)
        await controller.handleKeyboardCommand(.acceptSelected)
        XCTAssertTrue(replacer.replacements.isEmpty)
    }

    func testInvalidMacroNeverBecomesAcceptableAndReturnCancelsWithoutCommit() async {
        let contextProvider = MutableMacroContextProvider(context: textContext("hello ;;weather"))
        let replacer = RecordingMacroTextReplacer()
        let controller = makeController(contextProvider: contextProvider, replacer: replacer)

        let handled = await controller.handleInputEvent(.text(keyCode: 0, isSuggestionTrigger: false))
        XCTAssertTrue(handled)
        XCTAssertTrue(controller.isActive)
        XCTAssertEqual(controller.keyboardCapabilities, .inactive)

        let returnHandled = await controller.handleInputEvent(.text(keyCode: 36, isSuggestionTrigger: false))
        XCTAssertTrue(returnHandled)
        XCTAssertFalse(controller.isActive)
        XCTAssertTrue(replacer.replacements.isEmpty)
    }

    func testBackspaceUpdatesQueryAndOptionBackspaceCancels() async {
        let contextProvider = MutableMacroContextProvider(context: textContext("hello ;;2+2"))
        let controller = makeController(
            contextProvider: contextProvider,
            replacer: RecordingMacroTextReplacer()
        )
        _ = await controller.handleInputEvent(.text(keyCode: 0, isSuggestionTrigger: false))
        XCTAssertEqual(controller.activeQuery, "2+2")

        contextProvider.context = textContext("hello ;;2+")
        _ = await controller.handleInputEvent(.text(
            keyCode: CapturedInputEventAdapter.deleteKeyCode,
            isSuggestionTrigger: false
        ))
        XCTAssertEqual(controller.activeQuery, "2+")
        XCTAssertTrue(controller.isActive)

        _ = await controller.handleInputEvent(.shortcutMutation(
            keyCode: CapturedInputEventAdapter.deleteKeyCode
        ))
        XCTAssertFalse(controller.isActive)
    }

    func testCaptureRemainsActiveUntilHostPublishAwaitCompletes() async {
        let contextProvider = MutableMacroContextProvider(context: textContext("hello ;;2+2"))
        let controller = MacroCommandController(
            contextProvider: contextProvider,
            textReplacer: RecordingMacroTextReplacer(),
            evaluator: LocalMacroEvaluator(),
            panelController: RecordingMacroPanel(),
            hostPublishAwaiter: HostPublishAwaiter(configuration: .init(
                firstReadDelayNanoseconds: 10_000_000,
                pollIntervalNanoseconds: 10_000_000,
                timeoutNanoseconds: 40_000_000
            )),
            hostPublishDelayNanoseconds: 0,
            timeoutNanoseconds: 0
        )
        _ = await controller.handleInputEvent(.text(keyCode: 0, isSuggestionTrigger: false))

        let commit = Task { @MainActor in
            await controller.handleKeyboardCommand(.acceptSelected)
        }
        try? await Task.sleep(nanoseconds: 5_000_000)
        XCTAssertTrue(controller.isActive)
        await commit.value
        XCTAssertFalse(controller.isActive)
    }

    func testSecureContextDoesNotOpen() async {
        let contextProvider = MutableMacroContextProvider(
            context: nil,
            error: AXTextContextError.secureOrUnsupportedField
        )
        let diagnostics = InlineCommandDiagnostics()
        let controller = MacroCommandController(
            contextProvider: contextProvider,
            textReplacer: RecordingMacroTextReplacer(),
            evaluator: LocalMacroEvaluator(),
            panelController: RecordingMacroPanel(),
            diagnostics: diagnostics,
            hostPublishDelayNanoseconds: 0,
            timeoutNanoseconds: 0
        )

        let handled = await controller.handleInputEvent(.text(keyCode: 0, isSuggestionTrigger: false))
        XCTAssertFalse(handled)
        XCTAssertFalse(controller.isActive)
        XCTAssertEqual(diagnostics.snapshot.lastReason, .secureField)
    }

    private func makeController(
        contextProvider: MutableMacroContextProvider,
        replacer: RecordingMacroTextReplacer,
        panel: RecordingMacroPanel = RecordingMacroPanel()
    ) -> MacroCommandController {
        MacroCommandController(
            contextProvider: contextProvider,
            textReplacer: replacer,
            evaluator: LocalMacroEvaluator(),
            panelController: panel,
            hostPublishAwaiter: HostPublishAwaiter(configuration: .init(
                firstReadDelayNanoseconds: 0,
                pollIntervalNanoseconds: 0,
                timeoutNanoseconds: 0
            )),
            hostPublishDelayNanoseconds: 0,
            timeoutNanoseconds: 0
        )
    }

    private func textContext(_ text: String, focusSequence: UInt64 = 1) -> TextContext {
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
            textBeforeCursor: text,
            selectedRange: NSRange(location: text.utf16.count, length: 0),
            caretRect: CGRect(x: 20, y: 20, width: 2, height: 18),
            focusedElementRect: CGRect(x: 10, y: 10, width: 400, height: 200)
        )
    }
}

private final class MutableMacroContextProvider: TextContextProvider, @unchecked Sendable {
    var context: TextContext?
    var error: Error?

    init(context: TextContext?, error: Error? = nil) {
        self.context = context
        self.error = error
    }

    func currentContext() async throws -> TextContext {
        if let error { throw error }
        guard let context else { throw AXTextContextError.noReadableText }
        return context
    }
}

@MainActor
private final class RecordingMacroTextReplacer: EmojiTextReplacing {
    struct Replacement: Equatable {
        let utf16Length: Int
        let text: String
    }

    private(set) var replacements: [Replacement] = []
    private let onReplace: () -> Void

    init(onReplace: @escaping () -> Void = {}) {
        self.onReplace = onReplace
    }

    func replaceTrailingText(utf16Length: Int, with text: String) throws {
        replacements.append(.init(utf16Length: utf16Length, text: text))
        onReplace()
    }
}

@MainActor
private final class RecordingMacroPanel: MacroPreviewPanelControlling {
    private(set) var values: [MacroValue] = []
    private(set) var hideCount = 0

    func show(value: MacroValue, anchorContext: TextContext, acceptKeyLabel: String, onCommit: @escaping () -> Void) {
        values.append(value)
    }

    func hide() {
        hideCount += 1
    }
}
