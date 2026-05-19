import AutoCompCore
import CoreGraphics
@testable import AutoCompApp
import XCTest

@MainActor
final class SuggestionEngineAcceptanceTests: XCTestCase {
    func testCompletionRequiresObservedTrailingWhitespaceTrigger() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let initialContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please"
        )
        let triggeredContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please "
        )
        let contextProvider = MutableContextProvider(context: initialContext)
        let completionProvider = CountingCompletionProvider(
            suggestion: Suggestion(
                baseContextID: initialContext.id,
                visibleText: "continue this",
                latencyMs: 25
            )
        )
        let engine = SuggestionEngine(
            contextProvider: contextProvider,
            completionProvider: completionProvider,
            presenter: RecordingSuggestionPresenter()
        )

        engine.start()
        try await Task.sleep(nanoseconds: 650_000_000)
        let callCountBeforeSpace = await completionProvider.getCallCount()
        XCTAssertEqual(callCountBeforeSpace, 0)

        await contextProvider.updateContext(triggeredContext)
        try await Task.sleep(nanoseconds: 700_000_000)
        let callCountAfterSpace = await completionProvider.getCallCount()
        XCTAssertEqual(callCountAfterSpace, 1)
        engine.stop()
    }

    func testInitialTrailingWhitespaceDoesNotRequestCompletionWithoutObservedInput() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let initialContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Already typed "
        )
        let contextProvider = MutableContextProvider(context: initialContext)
        let completionProvider = CountingCompletionProvider(
            suggestion: Suggestion(
                baseContextID: initialContext.id,
                visibleText: "continuation",
                latencyMs: 25
            )
        )
        let engine = SuggestionEngine(
            contextProvider: contextProvider,
            completionProvider: completionProvider,
            presenter: RecordingSuggestionPresenter()
        )

        engine.start()
        try await Task.sleep(nanoseconds: 700_000_000)

        let callCount = await completionProvider.getCallCount()
        XCTAssertEqual(callCount, 0)
        engine.stop()
    }

    func testRecentSpaceKeyCanTriggerWhenFirstObservedContextAlreadyEndsWithSpace() async throws {
        let app = AppIdentity(bundleID: "com.google.Chrome", displayName: "Google Chrome", processID: 1)
        let initialContext = TextContext(
            app: app,
            domain: "docs.google.com",
            focusedElementID: "docs-field",
            textBeforeCursor: "Docs batch ",
            selectedRange: NSRange(location: 11, length: 0),
            caretRect: CGRect(x: 520, y: 381, width: 1, height: 16),
            focusedElementRect: CGRect(x: 520, y: 381, width: 626, height: 2)
        )
        let contextProvider = MutableContextProvider(context: initialContext)
        let completionProvider = CountingCompletionProvider(
            suggestion: Suggestion(
                baseContextID: initialContext.id,
                visibleText: "continue this",
                latencyMs: 25
            )
        )
        let presenter = RecordingSuggestionPresenter()
        let engine = SuggestionEngine(
            contextProvider: contextProvider,
            completionProvider: completionProvider,
            presenter: presenter
        )

        engine.start()
        engine.recordSuggestionTriggerKey()
        try await Task.sleep(nanoseconds: 700_000_000)

        let callCount = await completionProvider.getCallCount()
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(presenter.lastSuggestion?.visibleText, "continue this")
        engine.stop()
    }

    func testBatchInputAfterObservedEmptyContextCanTriggerOnTrailingSpace() async throws {
        let app = AppIdentity(bundleID: "com.openai.codex", displayName: "Codex", processID: 1)
        let emptyContext = TextContext(
            app: app,
            focusedElementID: "codex-field",
            textBeforeCursor: ""
        )
        let triggeredContext = TextContext(
            app: app,
            focusedElementID: "codex-field",
            textBeforeCursor: "Please "
        )
        let contextProvider = MutableContextProvider(context: emptyContext)
        let completionProvider = CountingCompletionProvider(
            suggestion: Suggestion(
                baseContextID: emptyContext.id,
                visibleText: "continue this",
                latencyMs: 25
            )
        )
        let engine = SuggestionEngine(
            contextProvider: contextProvider,
            completionProvider: completionProvider,
            presenter: RecordingSuggestionPresenter()
        )

        engine.start()
        try await Task.sleep(nanoseconds: 350_000_000)
        await contextProvider.updateContext(triggeredContext)
        try await Task.sleep(nanoseconds: 700_000_000)

        let callCount = await completionProvider.getCallCount()
        XCTAssertEqual(callCount, 1)
        engine.stop()
    }

    func testLeadingWhitespaceSuggestionIsTrimmedAfterSpaceTrigger() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let initialContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please"
        )
        let triggeredContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please "
        )
        let contextProvider = MutableContextProvider(context: initialContext)
        let completionProvider = CountingCompletionProvider(
            suggestion: Suggestion(
                baseContextID: initialContext.id,
                visibleText: " continue this",
                latencyMs: 25
            )
        )
        let presenter = RecordingSuggestionPresenter()
        let engine = SuggestionEngine(
            contextProvider: contextProvider,
            completionProvider: completionProvider,
            presenter: presenter
        )

        engine.start()
        try await Task.sleep(nanoseconds: 350_000_000)
        await contextProvider.updateContext(triggeredContext)
        try await Task.sleep(nanoseconds: 700_000_000)

        XCTAssertEqual(presenter.lastSuggestion?.visibleText, "continue this")

        let inserter = RecordingTextInserter()
        await engine.acceptNextWord(using: inserter)
        XCTAssertEqual(inserter.insertedText, "continue ")
        engine.stop()
    }

    func testBacktickTypedWithVisibleSuggestionIsPreservedAsUserInputWithoutAcceptingAll() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let initialContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please"
        )
        let triggeredContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please "
        )
        let backtickContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please `"
        )
        let contextProvider = MutableContextProvider(context: initialContext)
        let completionProvider = CountingCompletionProvider(
            suggestion: Suggestion(
                baseContextID: initialContext.id,
                visibleText: "finish the sentence",
                latencyMs: 25
            )
        )
        let repairer = RecordingShortcutLeakRepairer()
        let presenter = RecordingSuggestionPresenter()
        let engine = SuggestionEngine(
            contextProvider: contextProvider,
            completionProvider: completionProvider,
            presenter: presenter,
            shortcutLeakRepairInserter: repairer
        )

        engine.start()
        try await Task.sleep(nanoseconds: 350_000_000)
        await contextProvider.updateContext(triggeredContext)
        try await Task.sleep(nanoseconds: 700_000_000)
        let callCountBeforeBacktick = await completionProvider.getCallCount()
        XCTAssertEqual(callCountBeforeBacktick, 1)

        await contextProvider.updateContext(backtickContext)
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertNil(repairer.acceptedNextWordsText)
        XCTAssertNil(repairer.deletedLength)
        XCTAssertNil(engine.currentSuggestion)
        XCTAssertNil(presenter.lastSuggestion)
        let callCountAfterBacktick = await completionProvider.getCallCount()
        XCTAssertEqual(callCountAfterBacktick, 1)
        engine.stop()
    }

    func testBacktickTypedAfterAcceptAllIsPreservedAsUserInput() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let initialContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please"
        )
        let triggeredContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please "
        )
        let acceptedContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please finish the sentence`"
        )
        let contextProvider = MutableContextProvider(context: initialContext)
        let completionProvider = CountingCompletionProvider(
            suggestion: Suggestion(
                baseContextID: initialContext.id,
                visibleText: "finish the sentence",
                latencyMs: 25
            )
        )
        let inserter = RecordingTextInserter()
        let repairer = RecordingShortcutLeakRepairer()
        let presenter = RecordingSuggestionPresenter()
        let engine = SuggestionEngine(
            contextProvider: contextProvider,
            completionProvider: completionProvider,
            presenter: presenter,
            shortcutLeakRepairInserter: repairer
        )

        engine.start()
        try await Task.sleep(nanoseconds: 350_000_000)
        await contextProvider.updateContext(triggeredContext)
        try await Task.sleep(nanoseconds: 700_000_000)

        await engine.acceptAll(using: inserter)
        XCTAssertEqual(inserter.insertedText, "finish the sentence")

        await contextProvider.updateContext(acceptedContext)
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertNil(repairer.deletedLength)
        XCTAssertNil(repairer.acceptedNextWordsText)
        XCTAssertNil(engine.currentSuggestion)
        XCTAssertNil(presenter.lastSuggestion)
        let callCountAfterLeak = await completionProvider.getCallCount()
        XCTAssertEqual(callCountAfterLeak, 1)
        engine.stop()
    }

    func testWhitespaceNormalizedEchoAfterAcceptAllDoesNotRemoveUserSuffix() async throws {
        let app = AppIdentity(bundleID: "com.google.Chrome", displayName: "Google Chrome", processID: 1)
        let initialContext = TextContext(
            app: app,
            domain: "docs.google.com",
            focusedElementID: "docs-field-a",
            textBeforeCursor: "Docs",
            focusedElementRect: CGRect(x: 450, y: 381, width: 626, height: 2)
        )
        let triggeredContext = TextContext(
            app: app,
            domain: "docs.google.com",
            focusedElementID: "docs-field-b",
            textBeforeCursor: "Docs ",
            focusedElementRect: CGRect(x: 462, y: 381, width: 626, height: 2)
        )
        let settledContext = TextContext(
            app: app,
            domain: "docs.google.com",
            focusedElementID: "docs-field-c",
            textBeforeCursor: "Docs\u{00A0}finish the sentence",
            focusedElementRect: CGRect(x: 620, y: 381, width: 626, height: 2)
        )
        let acceptedContext = TextContext(
            app: app,
            domain: "docs.google.com",
            focusedElementID: "docs-field-d",
            textBeforeCursor: "Docs\u{00A0}finish the sentenceme",
            focusedElementRect: CGRect(x: 640, y: 381, width: 626, height: 2)
        )
        let contextProvider = MutableContextProvider(context: initialContext)
        let completionProvider = CountingCompletionProvider(
            suggestion: Suggestion(
                baseContextID: initialContext.id,
                visibleText: "finish the sentence",
                latencyMs: 25
            )
        )
        let inserter = RecordingTextInserter()
        let repairer = RecordingShortcutLeakRepairer()
        let engine = SuggestionEngine(
            contextProvider: contextProvider,
            completionProvider: completionProvider,
            presenter: RecordingSuggestionPresenter(),
            shortcutLeakRepairInserter: repairer
        )

        engine.start()
        try await Task.sleep(nanoseconds: 350_000_000)
        await contextProvider.updateContext(triggeredContext)
        try await Task.sleep(nanoseconds: 700_000_000)

        await engine.acceptAll(using: inserter)
        await contextProvider.updateContext(settledContext)
        try await Task.sleep(nanoseconds: 300_000_000)
        await contextProvider.updateContext(acceptedContext)
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertNil(repairer.deletedLength)
        XCTAssertNil(repairer.acceptedNextWordsText)
        let callCountAfterLeak = await completionProvider.getCallCount()
        XCTAssertEqual(callCountAfterLeak, 1)
        engine.stop()
    }

    func testWebLikeTrailingWhitespaceNormalizationKeepsSuggestionArmed() async throws {
        let app = AppIdentity(bundleID: "com.openai.codex", displayName: "Codex", processID: 1)
        let focusedRect = CGRect(x: 278, y: 829, width: 712, height: 44)
        let initialContext = TextContext(
            app: app,
            focusedElementID: "codex-field-a",
            textBeforeCursor: "Please",
            focusedElementRect: focusedRect
        )
        let triggeredContext = TextContext(
            app: app,
            focusedElementID: "codex-field-a",
            textBeforeCursor: "Please ",
            focusedElementRect: focusedRect
        )
        let normalizedContext = TextContext(
            app: app,
            focusedElementID: "codex-field-b",
            textBeforeCursor: "Please",
            focusedElementRect: focusedRect
        )
        let contextProvider = MutableContextProvider(context: initialContext)
        let completionProvider = CountingCompletionProvider(
            suggestion: Suggestion(
                baseContextID: initialContext.id,
                visibleText: "continue this",
                latencyMs: 25
            )
        )
        let presenter = RecordingSuggestionPresenter()
        let engine = SuggestionEngine(
            contextProvider: contextProvider,
            completionProvider: completionProvider,
            presenter: presenter
        )

        engine.start()
        try await Task.sleep(nanoseconds: 350_000_000)
        await contextProvider.updateContext(triggeredContext)
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(presenter.lastSuggestion?.visibleText, "continue this")

        await contextProvider.updateContext(normalizedContext)
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(engine.currentSuggestion?.visibleText, "continue this")
        XCTAssertEqual(presenter.lastSuggestion?.visibleText, "continue this")
        let callCount = await completionProvider.getCallCount()
        XCTAssertEqual(callCount, 1)
        engine.stop()
    }

    func testGoogleDocsBrailleMovingLineMetricStillTriggersAfterSpace() async throws {
        let app = AppIdentity(bundleID: "com.google.Chrome", displayName: "Google Chrome", processID: 1)
        let initialContext = TextContext(
            app: app,
            domain: "docs.google.com",
            focusedElementID: "docs-field-a",
            textBeforeCursor: "Docs tab ",
            selectedRange: NSRange(location: 9, length: 0),
            caretRect: CGRect(x: 480, y: 381, width: 1, height: 16),
            focusedElementRect: CGRect(x: 480, y: 381, width: 626, height: 1)
        )
        let triggeredContext = TextContext(
            app: app,
            domain: "docs.google.com",
            focusedElementID: "docs-field-b",
            textBeforeCursor: "Docs tab next ",
            selectedRange: NSRange(location: 14, length: 0),
            caretRect: CGRect(x: 512, y: 381, width: 1, height: 16),
            focusedElementRect: CGRect(x: 512, y: 381, width: 626, height: 1)
        )
        let contextProvider = MutableContextProvider(context: initialContext)
        let completionProvider = CountingCompletionProvider(
            suggestion: Suggestion(
                baseContextID: initialContext.id,
                visibleText: "continues cleanly",
                latencyMs: 25
            )
        )
        let presenter = RecordingSuggestionPresenter()
        let engine = SuggestionEngine(
            contextProvider: contextProvider,
            completionProvider: completionProvider,
            presenter: presenter
        )

        engine.start()
        try await Task.sleep(nanoseconds: 350_000_000)
        let callCountBeforeObservedInput = await completionProvider.getCallCount()
        XCTAssertEqual(callCountBeforeObservedInput, 0)

        await contextProvider.updateContext(triggeredContext)
        try await Task.sleep(nanoseconds: 700_000_000)

        let callCountAfterObservedInput = await completionProvider.getCallCount()
        XCTAssertEqual(callCountAfterObservedInput, 1)
        XCTAssertEqual(presenter.lastSuggestion?.visibleText, "continues cleanly")
        engine.stop()
    }

    func testGoogleDocsBrailleMovingLineMetricPreservesAcceptedSuggestionSession() async throws {
        let app = AppIdentity(bundleID: "com.google.Chrome", displayName: "Google Chrome", processID: 1)
        let initialContext = TextContext(
            app: app,
            domain: "docs.google.com",
            focusedElementID: "docs-field-a",
            textBeforeCursor: "Docs",
            selectedRange: NSRange(location: 4, length: 0),
            caretRect: CGRect(x: 450, y: 381, width: 1, height: 16),
            focusedElementRect: CGRect(x: 450, y: 381, width: 626, height: 1)
        )
        let triggeredContext = TextContext(
            app: app,
            domain: "docs.google.com",
            focusedElementID: "docs-field-b",
            textBeforeCursor: "Docs ",
            selectedRange: NSRange(location: 5, length: 0),
            caretRect: CGRect(x: 462, y: 381, width: 1, height: 16),
            focusedElementRect: CGRect(x: 462, y: 381, width: 626, height: 1)
        )
        let acceptedEchoContext = TextContext(
            app: app,
            domain: "docs.google.com",
            focusedElementID: "docs-field-c",
            textBeforeCursor: "Docs keep ",
            selectedRange: NSRange(location: 10, length: 0),
            caretRect: CGRect(x: 505, y: 381, width: 1, height: 16),
            focusedElementRect: CGRect(x: 505, y: 381, width: 626, height: 1)
        )
        let contextProvider = MutableContextProvider(context: initialContext)
        let completionProvider = CountingCompletionProvider(
            suggestion: Suggestion(
                baseContextID: initialContext.id,
                visibleText: "keep this suggestion stable",
                latencyMs: 25
            )
        )
        let presenter = RecordingSuggestionPresenter()
        let engine = SuggestionEngine(
            contextProvider: contextProvider,
            completionProvider: completionProvider,
            presenter: presenter
        )

        engine.start()
        try await Task.sleep(nanoseconds: 350_000_000)
        await contextProvider.updateContext(triggeredContext)
        try await Task.sleep(nanoseconds: 700_000_000)
        let initialCallCount = await completionProvider.getCallCount()
        XCTAssertEqual(initialCallCount, 1)

        let inserter = RecordingTextInserter()
        await engine.acceptNextWord(using: inserter)
        XCTAssertEqual(inserter.insertedText, "keep ")

        await contextProvider.updateContext(acceptedEchoContext)
        try await Task.sleep(nanoseconds: 1_900_000_000)

        let callCountAfterFocusedMetricMoved = await completionProvider.getCallCount()
        XCTAssertEqual(callCountAfterFocusedMetricMoved, 1)
        XCTAssertEqual(engine.statusMessage, "Continuing accepted suggestion")
        XCTAssertEqual(engine.currentSuggestion?.visibleText, "this suggestion stable")
        XCTAssertEqual(presenter.lastSuggestion?.visibleText, "this suggestion stable")
        engine.stop()
    }

    func testGoogleDocsAcceptedSuggestionToleratesWhitespaceNormalizedEcho() async throws {
        let app = AppIdentity(bundleID: "com.google.Chrome", displayName: "Google Chrome", processID: 1)
        let initialContext = TextContext(
            app: app,
            domain: "docs.google.com",
            focusedElementID: "docs-field-a",
            textBeforeCursor: "Docs tab",
            selectedRange: NSRange(location: 8, length: 0),
            caretRect: CGRect(x: 450, y: 381, width: 1, height: 16),
            focusedElementRect: CGRect(x: 450, y: 381, width: 626, height: 1)
        )
        let triggeredContext = TextContext(
            app: app,
            domain: "docs.google.com",
            focusedElementID: "docs-field-b",
            textBeforeCursor: "Docs tab \t",
            selectedRange: NSRange(location: 10, length: 0),
            caretRect: CGRect(x: 470, y: 381, width: 1, height: 16),
            focusedElementRect: CGRect(x: 470, y: 381, width: 626, height: 1)
        )
        let acceptedEchoContext = TextContext(
            app: app,
            domain: "docs.google.com",
            focusedElementID: "docs-field-c",
            textBeforeCursor: "Docs tab keep ",
            selectedRange: NSRange(location: 14, length: 0),
            caretRect: CGRect(x: 515, y: 381, width: 1, height: 16),
            focusedElementRect: CGRect(x: 515, y: 381, width: 626, height: 1)
        )
        let contextProvider = MutableContextProvider(context: initialContext)
        let completionProvider = CountingCompletionProvider(
            suggestion: Suggestion(
                baseContextID: initialContext.id,
                visibleText: "keep this suggestion stable",
                latencyMs: 25
            )
        )
        let presenter = RecordingSuggestionPresenter()
        let engine = SuggestionEngine(
            contextProvider: contextProvider,
            completionProvider: completionProvider,
            presenter: presenter
        )

        engine.start()
        try await Task.sleep(nanoseconds: 350_000_000)
        await contextProvider.updateContext(triggeredContext)
        try await Task.sleep(nanoseconds: 700_000_000)
        let initialCallCount = await completionProvider.getCallCount()
        XCTAssertEqual(initialCallCount, 1)

        let inserter = RecordingTextInserter()
        await engine.acceptNextWord(using: inserter)
        XCTAssertEqual(inserter.insertedText, "keep ")

        await contextProvider.updateContext(acceptedEchoContext)
        try await Task.sleep(nanoseconds: 1_900_000_000)

        let callCountAfterNormalizedEcho = await completionProvider.getCallCount()
        XCTAssertEqual(callCountAfterNormalizedEcho, 1)
        XCTAssertEqual(engine.statusMessage, "Continuing accepted suggestion")
        XCTAssertEqual(engine.currentSuggestion?.visibleText, "this suggestion stable")
        XCTAssertEqual(presenter.lastSuggestion?.visibleText, "this suggestion stable")
        engine.stop()
    }

    func testAcceptedSuggestionEchoDoesNotRequestNewCompletion() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let initialContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "I think"
        )
        let triggeredContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "I think "
        )
        let acceptedEchoContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "I think so "
        )
        let contextProvider = MutableContextProvider(context: initialContext)
        let completionProvider = CountingCompletionProvider(
            suggestion: Suggestion(
                baseContextID: initialContext.id,
                visibleText: "so this works",
                latencyMs: 25
            )
        )
        let presenter = RecordingSuggestionPresenter()
        let engine = SuggestionEngine(
            contextProvider: contextProvider,
            completionProvider: completionProvider,
            presenter: presenter
        )

        engine.start()
        try await Task.sleep(nanoseconds: 350_000_000)
        await contextProvider.updateContext(triggeredContext)
        try await Task.sleep(nanoseconds: 700_000_000)
        let initialCallCount = await completionProvider.getCallCount()
        XCTAssertEqual(initialCallCount, 1)

        let inserter = RecordingTextInserter()
        await engine.acceptNextWord(using: inserter)
        XCTAssertEqual(inserter.insertedText, "so ")

        await contextProvider.updateContext(acceptedEchoContext)
        try await Task.sleep(nanoseconds: 500_000_000)

        let callCountAfterAcceptance = await completionProvider.getCallCount()
        XCTAssertEqual(callCountAfterAcceptance, 1)
        XCTAssertEqual(engine.statusMessage, "Continuing accepted suggestion")
        XCTAssertEqual(presenter.lastSuggestion?.visibleText, "this works")
        engine.stop()
    }

    func testAcceptedSuggestionRemainsStableUntilUserTypesDifferentText() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let initialContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please"
        )
        let triggeredContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please "
        )
        let acceptedEchoContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please keep "
        )
        let divergentContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please keep typing "
        )
        let contextProvider = MutableContextProvider(context: initialContext)
        let completionProvider = CountingCompletionProvider(
            suggestion: Suggestion(
                baseContextID: initialContext.id,
                visibleText: "keep this suggestion",
                latencyMs: 25
            )
        )
        let engine = SuggestionEngine(
            contextProvider: contextProvider,
            completionProvider: completionProvider,
            presenter: RecordingSuggestionPresenter()
        )

        engine.start()
        try await Task.sleep(nanoseconds: 350_000_000)
        await contextProvider.updateContext(triggeredContext)
        try await Task.sleep(nanoseconds: 700_000_000)
        let initialCallCount = await completionProvider.getCallCount()
        XCTAssertEqual(initialCallCount, 1)

        let inserter = RecordingTextInserter()
        await engine.acceptNextWord(using: inserter)
        XCTAssertEqual(inserter.insertedText, "keep ")

        await contextProvider.updateContext(acceptedEchoContext)
        try await Task.sleep(nanoseconds: 2_700_000_000)
        let callCountAfterAcceptedTextSettled = await completionProvider.getCallCount()
        XCTAssertEqual(callCountAfterAcceptedTextSettled, 1)
        XCTAssertEqual(engine.currentSuggestion?.visibleText, "this suggestion")

        await contextProvider.updateContext(divergentContext)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let callCountAfterUserDiverged = await completionProvider.getCallCount()
        XCTAssertEqual(callCountAfterUserDiverged, 2)
        engine.stop()
    }

    func testRepeatedTabConsumesSameSuggestionWithoutNewCompletion() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let initialContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please"
        )
        let triggeredContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please "
        )
        let firstAcceptedEchoContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please keep "
        )
        let contextProvider = MutableContextProvider(context: initialContext)
        let completionProvider = CountingCompletionProvider(
            suggestion: Suggestion(
                baseContextID: initialContext.id,
                visibleText: "keep this suggestion stable",
                latencyMs: 25
            )
        )
        let presenter = RecordingSuggestionPresenter()
        let engine = SuggestionEngine(
            contextProvider: contextProvider,
            completionProvider: completionProvider,
            presenter: presenter
        )

        engine.start()
        try await Task.sleep(nanoseconds: 350_000_000)
        await contextProvider.updateContext(triggeredContext)
        try await Task.sleep(nanoseconds: 700_000_000)
        let initialCallCount = await completionProvider.getCallCount()
        XCTAssertEqual(initialCallCount, 1)

        let inserter = RecordingTextInserter()
        await engine.acceptNextWord(using: inserter)
        XCTAssertEqual(inserter.insertedText, "keep ")

        await contextProvider.updateContext(firstAcceptedEchoContext)
        try await Task.sleep(nanoseconds: 1_900_000_000)
        let callCountAfterFirstAcceptance = await completionProvider.getCallCount()
        XCTAssertEqual(callCountAfterFirstAcceptance, 1)
        XCTAssertEqual(engine.currentSuggestion?.visibleText, "this suggestion stable")

        await engine.acceptNextWord(using: inserter)
        XCTAssertEqual(inserter.insertedText, "keep this ")
        let callCountAfterSecondAcceptance = await completionProvider.getCallCount()
        XCTAssertEqual(callCountAfterSecondAcceptance, 1)
        XCTAssertEqual(engine.currentSuggestion?.visibleText, "suggestion stable")
        XCTAssertEqual(presenter.lastSuggestion?.visibleText, "suggestion stable")
        engine.stop()
    }

    func testAcceptedSuggestionSurvivesUnstableFocusedElementIDWhenRectMatches() async throws {
        let app = AppIdentity(bundleID: "com.apple.Notes", displayName: "Notes", processID: 1)
        let fieldRect = CGRect(x: 100, y: 200, width: 640, height: 80)
        let initialContext = TextContext(
            app: app,
            focusedElementID: "notes-field-a",
            textBeforeCursor: "Please",
            focusedElementRect: fieldRect
        )
        let triggeredContext = TextContext(
            app: app,
            focusedElementID: "notes-field-a",
            textBeforeCursor: "Please ",
            focusedElementRect: fieldRect
        )
        let acceptedEchoContext = TextContext(
            app: app,
            focusedElementID: "notes-field-b",
            textBeforeCursor: "Please keep ",
            focusedElementRect: fieldRect
        )
        let contextProvider = MutableContextProvider(context: initialContext)
        let completionProvider = CountingCompletionProvider(
            suggestion: Suggestion(
                baseContextID: initialContext.id,
                visibleText: "keep this suggestion stable",
                latencyMs: 25
            )
        )
        let presenter = RecordingSuggestionPresenter()
        let engine = SuggestionEngine(
            contextProvider: contextProvider,
            completionProvider: completionProvider,
            presenter: presenter
        )

        engine.start()
        try await Task.sleep(nanoseconds: 350_000_000)
        await contextProvider.updateContext(triggeredContext)
        try await Task.sleep(nanoseconds: 700_000_000)
        let initialCallCount = await completionProvider.getCallCount()
        XCTAssertEqual(initialCallCount, 1)

        let inserter = RecordingTextInserter()
        await engine.acceptNextWord(using: inserter)
        XCTAssertEqual(inserter.insertedText, "keep ")

        await contextProvider.updateContext(acceptedEchoContext)
        try await Task.sleep(nanoseconds: 1_900_000_000)

        let callCountAfterFocusedIDChanged = await completionProvider.getCallCount()
        XCTAssertEqual(callCountAfterFocusedIDChanged, 1)
        XCTAssertEqual(engine.statusMessage, "Continuing accepted suggestion")
        XCTAssertEqual(engine.currentSuggestion?.visibleText, "this suggestion stable")
        XCTAssertEqual(presenter.lastSuggestion?.visibleText, "this suggestion stable")
        engine.stop()
    }
}

private actor MutableContextProvider: TextContextProvider {
    private var context: TextContext

    init(context: TextContext) {
        self.context = context
    }

    func updateContext(_ context: TextContext) {
        self.context = context
    }

    func currentContext() async throws -> TextContext {
        context
    }
}

private actor CountingCompletionProvider: CompletionProvider {
    private let suggestion: Suggestion
    private var storedCallCount = 0

    func getCallCount() -> Int {
        storedCallCount
    }

    init(suggestion: Suggestion) {
        self.suggestion = suggestion
    }

    func complete(context: TextContext) async throws -> Suggestion {
        storedCallCount += 1
        return Suggestion(
            baseContextID: context.id,
            visibleText: suggestion.visibleText,
            latencyMs: suggestion.latencyMs
        )
    }
}

@MainActor
private final class RecordingSuggestionPresenter: SuggestionPresenter {
    private(set) var lastSuggestion: Suggestion?

    func show(_ suggestion: Suggestion, for context: TextContext, mode: SuggestionDisplayMode) {
        lastSuggestion = suggestion
    }

    func update(_ suggestion: Suggestion, for context: TextContext, mode: SuggestionDisplayMode) {
        lastSuggestion = suggestion
    }

    func hide() {
        lastSuggestion = nil
    }
}

@MainActor
private final class RecordingTextInserter: TextInserter {
    private(set) var insertedText = ""

    func acceptNextWord(from suggestion: inout Suggestion) async throws -> String? {
        guard let token = suggestion.acceptNextWord() else {
            return nil
        }
        insertedText += token
        return token
    }

    func acceptAll(from suggestion: inout Suggestion) async throws -> String? {
        guard let token = suggestion.acceptAll() else {
            return nil
        }
        insertedText += token
        return token
    }
}

@MainActor
private final class RecordingShortcutLeakRepairer: ShortcutLeakRepairing {
    private(set) var deletedLength: Int?
    private(set) var acceptedNextWordsText: String?

    func replaceLeakedShortcutSuffix(
        length: Int,
        withNextWordsFrom suggestion: inout Suggestion
    ) async throws -> String? {
        deletedLength = length
        let token = suggestion.acceptNextWord()
        acceptedNextWordsText = token
        return token
    }
}
