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
        XCTAssertEqual(engine.diagnostics.eligibility?.outcome, "ineligible")
        XCTAssertNotNil(engine.diagnostics.eligibility?.skipReason)
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
        engine.recordSuggestionTriggerKey(.text(keyCode: CapturedInputEventAdapter.spaceKeyCode, isSuggestionTrigger: true))
        try await Task.sleep(nanoseconds: 700_000_000)

        let callCount = await completionProvider.getCallCount()
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(presenter.lastSuggestion?.visibleText, "continue this")
        engine.stop()
    }

    func testCoordinatorConsumesInjectedFocusInputGenerationPresentationAndInsertionContracts() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let initialContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please "
        )
        let contextProvider = MutableContextProvider(context: initialContext)
        let completionProvider = CountingCompletionProvider(
            suggestion: Suggestion(
                baseContextID: initialContext.id,
                visibleText: "complete thought",
                latencyMs: 25
            )
        )
        let presenter = RecordingSuggestionPresenter()
        let inputController = RecordingInputController()
        let engine = SuggestionEngine(
            contextProvider: contextProvider,
            completionProvider: completionProvider,
            presenter: presenter,
            inputController: inputController
        )

        engine.start()
        engine.recordSuggestionTriggerKey(.text(keyCode: CapturedInputEventAdapter.spaceKeyCode, isSuggestionTrigger: true))
        try await Task.sleep(nanoseconds: 900_000_000)

        let callCount = await completionProvider.getCallCount()
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(inputController.recordedEvents, [.text(keyCode: 49, isSuggestionTrigger: true)])
        XCTAssertEqual(inputController.clearSuggestionTriggerCount, 1)
        XCTAssertEqual(presenter.lastSuggestion?.visibleText, "complete thought")

        let inserter = RecordingTextInserter()
        await engine.acceptNextWord(using: inserter)

        XCTAssertEqual(inserter.insertedText, "complete ")
        XCTAssertEqual(engine.currentSuggestion?.visibleText, "thought")
        XCTAssertEqual(presenter.lastSuggestion?.visibleText, "thought")
        engine.stop()
    }

    func testVisualContextProviderSnapshotFlowsIntoCompletionProvider() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AutoCompVisualFlow-\(UUID().uuidString)"))
        let privacyStore = PrivacySettingsStore(defaults: defaults, key: "privacy")
        try privacyStore.save(PrivacySettings(screenContextEnabled: true))
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let initialContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please "
        )
        let visualContext = VisualContextSnapshot(summary: "Visible title Budget Review")
        let completionProvider = RecordingVisualContextCompletionProvider()
        let engine = SuggestionEngine(
            contextProvider: MutableContextProvider(context: initialContext),
            completionProvider: completionProvider,
            visualContextProvider: StaticVisualContextProvider(snapshot: visualContext),
            presenter: RecordingSuggestionPresenter(),
            privacyStore: privacyStore
        )

        engine.start()
        engine.recordSuggestionTriggerKey(.text(keyCode: CapturedInputEventAdapter.spaceKeyCode, isSuggestionTrigger: true))
        try await Task.sleep(nanoseconds: 900_000_000)

        let recordedVisualContext = await completionProvider.recordedVisualContext()
        let recordedPrivacySettings = await completionProvider.recordedPrivacySettings()
        XCTAssertEqual(recordedVisualContext, visualContext)
        XCTAssertEqual(recordedPrivacySettings?.screenContextEnabled, true)
        engine.stop()
    }

    func testLateCompletionIsDiscardedWhenLiveContextChanges() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let requestedContext = TextContext(
            app: app,
            focusedElementID: "textedit-field-a",
            textBeforeCursor: "Please "
        )
        let changedContext = TextContext(
            app: app,
            focusedElementID: "textedit-field-b",
            textBeforeCursor: "Different"
        )
        let contextProvider = MutableContextProvider(context: requestedContext)
        let completionProvider = DelayedCompletionProvider(
            visibleText: "continue this",
            delayNanoseconds: 700_000_000
        )
        let presenter = RecordingSuggestionPresenter()
        let engine = SuggestionEngine(
            contextProvider: contextProvider,
            completionProvider: completionProvider,
            presenter: presenter
        )

        engine.start()
        engine.recordSuggestionTriggerKey(.text(keyCode: CapturedInputEventAdapter.spaceKeyCode, isSuggestionTrigger: true))
        try await Task.sleep(nanoseconds: 650_000_000)
        await contextProvider.updateContext(changedContext)
        try await Task.sleep(nanoseconds: 900_000_000)

        let callCount = await completionProvider.getCallCount()
        XCTAssertEqual(callCount, 1)
        XCTAssertNil(engine.currentSuggestion)
        XCTAssertNil(presenter.lastSuggestion)
        XCTAssertEqual(engine.diagnostics.backend.status, .discarded)
        XCTAssertNotNil(engine.diagnostics.staleDiscardReason)
        engine.stop()
    }

    func testDiagnosticsRecordCompletionSuccessWithPrivacyAllowedOutput() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AutoCompDiagnostics-\(UUID().uuidString)"))
        let privacyStore = PrivacySettingsStore(defaults: defaults, key: "privacy")
        try privacyStore.save(PrivacySettings(collectionEnabled: true))
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let initialContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please "
        )
        let contextProvider = MutableContextProvider(context: initialContext)
        let completionProvider = RawSuggestionCompletionProvider(
            rawText: "Completion:\n continue this",
            visibleText: " continue this"
        )
        let engine = SuggestionEngine(
            contextProvider: contextProvider,
            completionProvider: completionProvider,
            presenter: RecordingSuggestionPresenter(),
            privacyStore: privacyStore
        )

        engine.start()
        engine.recordSuggestionTriggerKey(.text(keyCode: CapturedInputEventAdapter.spaceKeyCode, isSuggestionTrigger: true))
        try await Task.sleep(nanoseconds: 900_000_000)

        XCTAssertEqual(engine.diagnostics.focus?.appDisplayName, "TextEdit")
        XCTAssertEqual(engine.diagnostics.eligibility?.outcome, "eligible")
        XCTAssertEqual(engine.diagnostics.backend.status, .success)
        XCTAssertEqual(engine.diagnostics.output.rawPreview, "Completion:  continue this")
        XCTAssertEqual(engine.diagnostics.output.normalizedPreview, "continue this")
        engine.stop()
    }

    func testDiagnosticsRecordCompletionFailure() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let initialContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please "
        )
        let contextProvider = MutableContextProvider(context: initialContext)
        let engine = SuggestionEngine(
            contextProvider: contextProvider,
            completionProvider: FailingCompletionProvider(),
            presenter: RecordingSuggestionPresenter()
        )

        engine.start()
        engine.recordSuggestionTriggerKey(.text(keyCode: CapturedInputEventAdapter.spaceKeyCode, isSuggestionTrigger: true))
        try await Task.sleep(nanoseconds: 900_000_000)

        XCTAssertEqual(engine.diagnostics.backend.status, .failed)
        XCTAssertEqual(engine.diagnostics.backend.lastError, "Test completion failed.")
        XCTAssertNil(engine.diagnostics.output.normalizedPreview)
        engine.stop()
    }

    func testLateCompletionPublishesWhenFocusedElementIDChangesButGeometryMatches() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let requestedContext = TextContext(
            app: app,
            focusedElementID: "textedit-field-a",
            textBeforeCursor: "Please ",
            selectedRange: NSRange(location: 7, length: 0),
            caretRect: CGRect(x: 260, y: 110, width: 1, height: 18),
            focusedElementRect: CGRect(x: 200, y: 100, width: 600, height: 40)
        )
        let recycledFocusContext = TextContext(
            app: app,
            focusedElementID: "textedit-field-b",
            textBeforeCursor: "Please ",
            selectedRange: NSRange(location: 7, length: 0),
            caretRect: CGRect(x: 261, y: 110, width: 1, height: 18),
            focusedElementRect: CGRect(x: 201, y: 101, width: 600, height: 40)
        )
        let contextProvider = MutableContextProvider(context: requestedContext)
        let completionProvider = DelayedCompletionProvider(
            visibleText: "continue this",
            delayNanoseconds: 700_000_000
        )
        let presenter = RecordingSuggestionPresenter()
        let engine = SuggestionEngine(
            contextProvider: contextProvider,
            completionProvider: completionProvider,
            presenter: presenter
        )

        engine.start()
        engine.recordSuggestionTriggerKey(.text(keyCode: CapturedInputEventAdapter.spaceKeyCode, isSuggestionTrigger: true))
        try await Task.sleep(nanoseconds: 650_000_000)
        await contextProvider.updateContext(recycledFocusContext)
        try await Task.sleep(nanoseconds: 900_000_000)

        let callCount = await completionProvider.getCallCount()
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(engine.currentSuggestion?.visibleText, "continue this")
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

    func testGoogleDocsScreenOCRJitterKeepsPublishedSuggestionVisible() async throws {
        let app = AppIdentity(bundleID: "com.google.Chrome", displayName: "Google Chrome", processID: 1)
        let initialContext = TextContext(
            app: app,
            domain: "docs.google.com",
            focusedElementID: "docs-field-a",
            textBeforeCursor: "Testando uma ferramenta de",
            caretRect: CGRect(x: 1218.3, y: 518.8, width: 1, height: 14.9),
            focusedElementRect: CGRect(x: 1033.4, y: 510.8, width: 512.9, height: 40),
            caretGeometryQuality: .screenOCR,
            captureSources: [.accessibility, .screenOCR]
        )
        let triggeredContext = TextContext(
            app: app,
            domain: "docs.google.com",
            focusedElementID: "docs-field-a",
            textBeforeCursor: "Testando uma ferramenta de ",
            caretRect: CGRect(x: 1225.3, y: 518.8, width: 1, height: 14.9),
            focusedElementRect: CGRect(x: 1033.4, y: 510.8, width: 512.9, height: 40),
            caretGeometryQuality: .screenOCR,
            captureSources: [.accessibility, .screenOCR]
        )
        let jitterContext = TextContext(
            app: app,
            domain: "docs.google.com",
            focusedElementID: "docs-field-b",
            textBeforeCursor: "Testando uma ferramenta de ",
            caretRect: CGRect(x: 1215.4, y: 518.8, width: 1, height: 14.9),
            focusedElementRect: CGRect(x: 1033.4, y: 510.8, width: 503.0, height: 40),
            caretGeometryQuality: .screenOCR,
            captureSources: [.accessibility, .screenOCR]
        )
        let contextProvider = MutableContextProvider(context: initialContext)
        let completionProvider = CountingCompletionProvider(
            suggestion: Suggestion(
                baseContextID: initialContext.id,
                visibleText: "continuar agora",
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
        XCTAssertEqual(presenter.lastSuggestion?.visibleText, "continuar agora")

        await contextProvider.updateContext(jitterContext)
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(engine.currentSuggestion?.visibleText, "continuar agora")
        XCTAssertEqual(presenter.lastSuggestion?.visibleText, "continuar agora")
        XCTAssertEqual(presenter.lastContext?.focusedElementID, "docs-field-b")
        let callCount = await completionProvider.getCallCount()
        XCTAssertEqual(callCount, 1)
        engine.stop()
    }

    func testGoogleDocsTransientFocusFailureKeepsPublishedSuggestionVisible() async throws {
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
        let contextProvider = MutableFailingContextProvider(context: initialContext)
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

        await contextProvider.fail(with: .noReadableText)
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

    func testAcceptNextWordUsesPredictedCaretUntilAccessibilityRefresh() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let initialContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please",
            selectedRange: NSRange(location: 6, length: 0),
            caretRect: CGRect(x: 180, y: 381, width: 2, height: 18),
            focusedElementRect: CGRect(x: 100, y: 360, width: 500, height: 40),
            previousGlyphRect: CGRect(x: 171, y: 381, width: 8, height: 18)
        )
        let triggeredContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please ",
            selectedRange: NSRange(location: 7, length: 0),
            caretRect: CGRect(x: 188, y: 381, width: 2, height: 18),
            focusedElementRect: CGRect(x: 100, y: 360, width: 500, height: 40),
            previousGlyphRect: CGRect(x: 179, y: 381, width: 8, height: 18)
        )
        let acceptedEchoContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please continue ",
            selectedRange: NSRange(location: 16, length: 0),
            caretRect: CGRect(x: 263, y: 381, width: 2, height: 18),
            focusedElementRect: CGRect(x: 100, y: 360, width: 500, height: 40),
            previousGlyphRect: CGRect(x: 254, y: 381, width: 8, height: 18)
        )
        let contextProvider = MutableContextProvider(context: initialContext)
        let completionProvider = CountingCompletionProvider(
            suggestion: Suggestion(
                baseContextID: initialContext.id,
                visibleText: "continue this suggestion",
                latencyMs: 25
            )
        )
        let inserter = RecordingTextInserter()
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

        await engine.acceptNextWord(using: inserter)

        XCTAssertEqual(inserter.insertedText, "continue ")
        XCTAssertEqual(presenter.lastSuggestion?.visibleText, "this suggestion")
        XCTAssertEqual(presenter.lastContext?.textBeforeCursor, "Please continue ")
        XCTAssertEqual(presenter.lastContext?.caretRect, CGRect(x: 260, y: 381, width: 2, height: 18))

        await contextProvider.updateContext(acceptedEchoContext)
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(presenter.lastSuggestion?.visibleText, "this suggestion")
        XCTAssertEqual(presenter.lastContext?.caretRect, acceptedEchoContext.caretRect)
        engine.stop()
    }

    func testTypingThroughAcceptedSuggestionAdvancesRemainingTail() async throws {
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
            textBeforeCursor: "Please continue "
        )
        let typedThroughContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please continue t"
        )
        let contextProvider = MutableContextProvider(context: initialContext)
        let completionProvider = CountingCompletionProvider(
            suggestion: Suggestion(
                baseContextID: initialContext.id,
                visibleText: "continue this suggestion",
                latencyMs: 25
            )
        )
        let inserter = RecordingTextInserter()
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

        await engine.acceptNextWord(using: inserter)
        await contextProvider.updateContext(acceptedEchoContext)
        try await Task.sleep(nanoseconds: 350_000_000)
        await contextProvider.updateContext(typedThroughContext)
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(engine.statusMessage, "Continuing accepted suggestion")
        XCTAssertEqual(engine.currentSuggestion?.visibleText, "his suggestion")
        XCTAssertEqual(presenter.lastSuggestion?.visibleText, "his suggestion")
        let callCount = await completionProvider.getCallCount()
        XCTAssertEqual(callCount, 1)
        engine.stop()
    }

    func testTypingThroughPublishedSuggestionBeforeTabAdvancesRemainingTail() async throws {
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
        let typedThroughContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please c"
        )
        let contextProvider = MutableContextProvider(context: initialContext)
        let completionProvider = CountingCompletionProvider(
            suggestion: Suggestion(
                baseContextID: initialContext.id,
                visibleText: "continue this suggestion",
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
        XCTAssertEqual(presenter.lastSuggestion?.visibleText, "continue this suggestion")

        await contextProvider.updateContext(typedThroughContext)
        try await Task.sleep(nanoseconds: 500_000_000)

        XCTAssertEqual(engine.statusMessage, "Continuing accepted suggestion")
        XCTAssertEqual(engine.currentSuggestion?.visibleText, "ontinue this suggestion")
        XCTAssertEqual(presenter.lastSuggestion?.visibleText, "ontinue this suggestion")
        let callCount = await completionProvider.getCallCount()
        XCTAssertEqual(callCount, 1)
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

private actor MutableFailingContextProvider: TextContextProvider {
    private var context: TextContext
    private var error: AXTextContextError?

    init(context: TextContext) {
        self.context = context
    }

    func updateContext(_ context: TextContext) {
        self.context = context
        error = nil
    }

    func fail(with error: AXTextContextError) {
        self.error = error
    }

    func currentContext() async throws -> TextContext {
        if let error {
            throw error
        }
        return context
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

private actor DelayedCompletionProvider: CompletionProvider {
    private let visibleText: String
    private let delayNanoseconds: UInt64
    private var storedCallCount = 0

    init(visibleText: String, delayNanoseconds: UInt64) {
        self.visibleText = visibleText
        self.delayNanoseconds = delayNanoseconds
    }

    func getCallCount() -> Int {
        storedCallCount
    }

    func complete(context: TextContext) async throws -> Suggestion {
        storedCallCount += 1
        try? await Task.sleep(nanoseconds: delayNanoseconds)
        return Suggestion(
            baseContextID: context.id,
            visibleText: visibleText,
            latencyMs: Int(delayNanoseconds / 1_000_000)
        )
    }
}

private actor RawSuggestionCompletionProvider: CompletionProvider {
    private let rawText: String
    private let visibleText: String

    init(rawText: String, visibleText: String) {
        self.rawText = rawText
        self.visibleText = visibleText
    }

    func complete(context: TextContext) async throws -> Suggestion {
        Suggestion(
            baseContextID: context.id,
            visibleText: visibleText,
            rawText: rawText,
            latencyMs: 12
        )
    }
}

private actor FailingCompletionProvider: CompletionProvider {
    func complete(context: TextContext) async throws -> Suggestion {
        throw TestCompletionError.failed
    }
}

private struct StaticVisualContextProvider: VisualContextProvider {
    let snapshot: VisualContextSnapshot?

    func currentVisualContext() async -> VisualContextSnapshot? {
        snapshot
    }
}

private actor RecordingVisualContextCompletionProvider: VisualContextAwareCompletionProvider {
    private var storedVisualContext: VisualContextSnapshot?
    private var storedPrivacySettings: PrivacySettings?

    func recordedVisualContext() -> VisualContextSnapshot? {
        storedVisualContext
    }

    func recordedPrivacySettings() -> PrivacySettings? {
        storedPrivacySettings
    }

    func complete(context: TextContext) async throws -> Suggestion {
        try await complete(context: context, privacySettings: PrivacySettings(), visualContext: nil)
    }

    func complete(
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?
    ) async throws -> Suggestion {
        storedPrivacySettings = privacySettings
        storedVisualContext = visualContext
        return Suggestion(baseContextID: context.id, visibleText: "continue this", latencyMs: 12)
    }
}

private enum TestCompletionError: LocalizedError {
    case failed

    var errorDescription: String? {
        "Test completion failed."
    }
}

@MainActor
private final class RecordingInputController: SuggestionInputStateTracking {
    private(set) var recordedEvents: [CapturedInputEvent] = []
    private(set) var clearSuggestionTriggerCount = 0
    private(set) var resetCount = 0
    private(set) var lastSuggestionTriggerKeyAt: Date = .distantPast

    func record(_ event: CapturedInputEvent) {
        recordedEvents.append(event)
        if event.isSuggestionTrigger {
            lastSuggestionTriggerKeyAt = Date()
        }
    }

    func clearSuggestionTrigger() {
        clearSuggestionTriggerCount += 1
        lastSuggestionTriggerKeyAt = .distantPast
    }

    func reset() {
        resetCount += 1
        lastSuggestionTriggerKeyAt = .distantPast
    }
}

@MainActor
private final class RecordingSuggestionPresenter: SuggestionPresenter {
    private(set) var lastSuggestion: Suggestion?
    private(set) var lastContext: TextContext?

    func show(_ suggestion: Suggestion, for context: TextContext, mode: SuggestionDisplayMode) {
        lastSuggestion = suggestion
        lastContext = context
    }

    func update(_ suggestion: Suggestion, for context: TextContext, mode: SuggestionDisplayMode) {
        lastSuggestion = suggestion
        lastContext = context
    }

    func hide() {
        lastSuggestion = nil
        lastContext = nil
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
