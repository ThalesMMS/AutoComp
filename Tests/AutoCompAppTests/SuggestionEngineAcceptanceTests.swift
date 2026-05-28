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

    func testCapturedTextEventSchedulesPredictionWithoutPollingTimer() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let context = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please "
        )
        let completionProvider = CountingCompletionProvider(
            suggestion: Suggestion(
                baseContextID: context.id,
                visibleText: "continue this",
                latencyMs: 25
            )
        )
        let presenter = RecordingSuggestionPresenter()
        let engine = SuggestionEngine(
            contextProvider: MutableContextProvider(context: context),
            completionProvider: completionProvider,
            presenter: presenter
        )

        engine.recordCapturedInputEvent(.text(keyCode: CapturedInputEventAdapter.spaceKeyCode, isSuggestionTrigger: true))
        try await Task.sleep(nanoseconds: 700_000_000)

        let callCount = await completionProvider.getCallCount()
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(engine.currentSuggestion?.visibleText, "continue this")
        XCTAssertEqual(presenter.lastSuggestion?.visibleText, "continue this")
    }

    func testPromptCacheDiagnosticsRecordedAfterCompletion() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let context = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please "
        )
        let completionProvider = PromptCacheStatsCompletionProvider(
            suggestion: Suggestion(
                baseContextID: context.id,
                visibleText: "continue this",
                latencyMs: 25
            ),
            stats: LlamaPromptCacheStats(
                hits: 4,
                misses: 2,
                resets: 1,
                retainedPromptTokens: 55,
                contextTokens: 512
            )
        )
        let engine = SuggestionEngine(
            contextProvider: MutableContextProvider(context: context),
            completionProvider: completionProvider,
            presenter: RecordingSuggestionPresenter()
        )

        engine.recordCapturedInputEvent(.text(keyCode: CapturedInputEventAdapter.spaceKeyCode, isSuggestionTrigger: true))
        try await Task.sleep(nanoseconds: 700_000_000)

        XCTAssertEqual(engine.currentSuggestion?.visibleText, "continue this")
        XCTAssertEqual(engine.diagnostics.promptCache?.hits, 4)
        XCTAssertTrue(engine.diagnostics.menuRows.contains {
            $0.id == "promptCache" && $0.value.contains("hits 4")
        })
    }

    func testBackspaceInputEventClearsVisibleSuggestionWithoutSchedulingPrediction() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let context = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please "
        )
        let completionProvider = CountingCompletionProvider(
            suggestion: Suggestion(
                baseContextID: context.id,
                visibleText: "continue this",
                latencyMs: 25
            )
        )
        let presenter = RecordingSuggestionPresenter()
        let engine = SuggestionEngine(
            contextProvider: MutableContextProvider(context: context),
            completionProvider: completionProvider,
            presenter: presenter
        )

        engine.recordCapturedInputEvent(.text(keyCode: CapturedInputEventAdapter.spaceKeyCode, isSuggestionTrigger: true))
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertNotNil(engine.currentSuggestion)

        engine.recordCapturedInputEvent(.text(keyCode: 51, isSuggestionTrigger: false))
        try await Task.sleep(nanoseconds: 350_000_000)

        let callCount = await completionProvider.getCallCount()
        XCTAssertEqual(callCount, 1)
        XCTAssertNil(engine.currentSuggestion)
        XCTAssertNil(presenter.lastSuggestion)
    }

    func testManualTriggerRequestsCompletionWithoutTrailingWhitespace() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let context = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please"
        )
        let contextProvider = MutableContextProvider(context: context)
        let completionProvider = CountingCompletionProvider(
            suggestion: Suggestion(
                baseContextID: context.id,
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

        await engine.triggerManualSuggestion()
        try await Task.sleep(nanoseconds: 100_000_000)

        let callCount = await completionProvider.getCallCount()
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(engine.diagnostics.eligibility?.outcome, "eligible")
        XCTAssertEqual(presenter.lastSuggestion?.visibleText, " continue this")
        engine.stop()
    }

    func testManualTriggerWithSelectionRequestsFIMAndTabReplacesSelection() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let prefix = "A reuniao foi "
        let selectedText = "adiada"
        let suffix = " porque o prazo mudou."
        let selectedRange = NSRange(
            location: (prefix as NSString).length,
            length: (selectedText as NSString).length
        )
        let context = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: prefix,
            textAfterCursor: suffix,
            selectedText: selectedText,
            fullTextWindow: prefix + selectedText + suffix,
            selectedRange: selectedRange
        )
        let contextProvider = MutableContextProvider(context: context)
        let completionProvider = RecordingContextCompletionProvider(visibleText: "realizada")
        let engine = SuggestionEngine(
            contextProvider: contextProvider,
            completionProvider: completionProvider,
            presenter: RecordingSuggestionPresenter()
        )

        await engine.triggerManualSuggestion()
        try await Task.sleep(nanoseconds: 100_000_000)

        let recordedContexts = await completionProvider.recordedContexts()
        let recordedContext = try XCTUnwrap(recordedContexts.first)
        XCTAssertEqual(PromptBuilder().mode(for: recordedContext), .fillInMiddle)
        XCTAssertEqual(recordedContext.textBeforeCursor, prefix)
        XCTAssertEqual(recordedContext.selectedText, selectedText)
        XCTAssertEqual(recordedContext.textAfterCursor, suffix)
        XCTAssertEqual(engine.currentSuggestion?.visibleText, "realizada")

        let inserter = ReplacingSelectionTextInserter(
            documentText: prefix + selectedText + suffix,
            selectedRange: selectedRange
        )
        let outcome = await engine.acceptNextWord(using: inserter)

        XCTAssertEqual(outcome, .accepted)
        XCTAssertEqual(inserter.insertedText, "realizada")
        XCTAssertEqual(inserter.documentText, prefix + "realizada" + suffix)
        engine.stop()
    }

    func testSelectionDoesNotAutoTriggerCompletion() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let prefix = "A reuniao foi "
        let selectedText = "adiada"
        let context = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: prefix,
            textAfterCursor: " porque o prazo mudou.",
            selectedText: selectedText,
            selectedRange: NSRange(
                location: (prefix as NSString).length,
                length: (selectedText as NSString).length
            )
        )
        let completionProvider = CountingCompletionProvider(
            suggestion: Suggestion(
                baseContextID: context.id,
                visibleText: "realizada",
                latencyMs: 25
            )
        )
        let engine = SuggestionEngine(
            contextProvider: MutableContextProvider(context: context),
            completionProvider: completionProvider,
            presenter: RecordingSuggestionPresenter()
        )

        engine.recordCapturedInputEvent(.text(keyCode: CapturedInputEventAdapter.spaceKeyCode, isSuggestionTrigger: true))
        try await Task.sleep(nanoseconds: 700_000_000)

        let callCount = await completionProvider.getCallCount()
        XCTAssertEqual(callCount, 0)
        XCTAssertNil(engine.currentSuggestion)
        XCTAssertEqual(engine.statusMessage, "Selection active")
        engine.stop()
    }

    func testDismissWithSelectionCancelsReplacementWithoutChangingText() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let prefix = "A reuniao foi "
        let selectedText = "adiada"
        let suffix = " porque o prazo mudou."
        let selectedRange = NSRange(
            location: (prefix as NSString).length,
            length: (selectedText as NSString).length
        )
        let originalText = prefix + selectedText + suffix
        let context = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: prefix,
            textAfterCursor: suffix,
            selectedText: selectedText,
            fullTextWindow: originalText,
            selectedRange: selectedRange
        )
        let engine = SuggestionEngine(
            contextProvider: MutableContextProvider(context: context),
            completionProvider: RecordingContextCompletionProvider(visibleText: "realizada"),
            presenter: RecordingSuggestionPresenter()
        )

        await engine.triggerManualSuggestion()
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertNotNil(engine.currentSuggestion)

        engine.dismissSuggestionUntilTextMutation()
        let inserter = ReplacingSelectionTextInserter(
            documentText: originalText,
            selectedRange: selectedRange
        )
        let outcome = await engine.acceptNextWord(using: inserter)

        XCTAssertEqual(outcome, .passedThrough)
        XCTAssertEqual(inserter.insertedText, "")
        XCTAssertEqual(inserter.documentText, originalText)
        engine.stop()
    }

    func testManualTriggerUsesLowTrustBufferWhenContextReadFails() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AutoCompLowTrustFallback-\(UUID().uuidString)"))
        let privacyStore = PrivacySettingsStore(defaults: defaults, key: "privacy")
        try privacyStore.save(PrivacySettings(clipboardContextEnabled: true, screenContextEnabled: true))
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let context = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "ignored"
        )
        let contextProvider = MutableFailingContextProvider(context: context)
        await contextProvider.fail(with: .noReadableText)
        let completionProvider = RecordingClipboardContextCompletionProvider()
        let visualContextProvider = StaticVisualContextProvider(
            snapshot: VisualContextSnapshot(summary: "Visual OCR summary")
        )
        let clipboardContext = ClipboardContextSnapshot(
            summary: "Clipboard summary",
            status: .included,
            captureSources: [.clipboard]
        )
        let presenter = RecordingSuggestionPresenter()
        let fallback = KeystrokeBufferFallback(
            frontmostAppProvider: { app },
            characterTranslator: TestKeystrokeCharacterTranslator(characters: [35: "p"])
        )
        fallback.record(event: .text(keyCode: 35, isSuggestionTrigger: false), currentContext: nil, inputMethodState: .asciiCompatible)
        let engine = SuggestionEngine(
            contextProvider: contextProvider,
            completionProvider: completionProvider,
            visualContextProvider: visualContextProvider,
            clipboardContextProvider: StaticClipboardContextProvider(snapshot: clipboardContext),
            presenter: presenter,
            privacyStore: privacyStore,
            keystrokeBufferFallback: fallback
        )

        await engine.triggerManualSuggestion()
        try await Task.sleep(nanoseconds: 100_000_000)

        let recordedContext = await completionProvider.recordedContext()
        let recordedVisualContext = await completionProvider.recordedVisualContext()
        let recordedClipboardContext = await completionProvider.recordedClipboardContext()
        XCTAssertEqual(recordedContext?.textBeforeCursor, "p")
        XCTAssertEqual(recordedContext?.captureSources, [.keystrokeBufferLowTrust])
        XCTAssertNil(recordedVisualContext)
        XCTAssertNil(recordedClipboardContext)
        XCTAssertEqual(engine.diagnostics.focus?.contextSource, "Keystroke buffer")
        XCTAssertEqual(engine.diagnostics.focus?.geometryQuality, "unavailable")
        XCTAssertEqual(engine.diagnostics.focus?.contextTrust, "low-trust")
        XCTAssertTrue(engine.diagnostics.menuRows.contains {
            $0.id == "contextSource" && $0.value == "Keystroke buffer"
        })
        XCTAssertTrue(engine.diagnostics.menuRows.contains {
            $0.id == "contextWarning"
                && $0.value == "Low-trust fallback: visual and clipboard context isolated."
        })
        XCTAssertTrue(engine.diagnostics.menuRows.contains {
            $0.id == "supplementalContext" && $0.value == "none (low-trust isolation)"
        })
        XCTAssertTrue(engine.diagnostics.menuRows.contains {
            $0.id == "visualContext" && $0.value == "none"
        })
        XCTAssertTrue(engine.diagnostics.menuRows.contains {
            $0.id == "clipboardContext" && $0.value == "none"
        })
        XCTAssertEqual(presenter.lastSuggestion?.visibleText, "continue this")
        engine.stop()
    }

    func testManualTriggerDoesNotUseLowTrustBufferInSecureFields() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let context = TextContext(
            app: app,
            focusedElementID: "secure-field",
            textBeforeCursor: "ignored"
        )
        let contextProvider = MutableFailingContextProvider(context: context)
        await contextProvider.fail(with: .secureOrUnsupportedField)
        let completionProvider = RecordingContextCompletionProvider(visibleText: "secret")
        let fallback = KeystrokeBufferFallback(
            frontmostAppProvider: { app },
            characterTranslator: TestKeystrokeCharacterTranslator(characters: [35: "p"])
        )
        fallback.record(event: .text(keyCode: 35, isSuggestionTrigger: false), currentContext: nil, inputMethodState: .asciiCompatible)
        let engine = SuggestionEngine(
            contextProvider: contextProvider,
            completionProvider: completionProvider,
            presenter: RecordingSuggestionPresenter(),
            keystrokeBufferFallback: fallback
        )

        await engine.triggerManualSuggestion()
        try await Task.sleep(nanoseconds: 100_000_000)

        let recordedContexts = await completionProvider.recordedContexts()
        XCTAssertEqual(recordedContexts.count, 0)
        XCTAssertNil(engine.currentSuggestion)
        XCTAssertEqual(fallback.bufferedText, "")
        engine.stop()
    }

    func testSecureFieldRevalidationBlocksBackendOverlayAndShortcutAcceptance() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let context = TextContext(
            app: app,
            focusedElementID: "normal-field",
            textBeforeCursor: "normal text "
        )
        let contextProvider = MutableFailingContextProvider(context: context)
        let completionProvider = RecordingContextCompletionProvider(visibleText: "suggestion")
        let presenter = RecordingSuggestionPresenter()
        let engine = SuggestionEngine(
            contextProvider: contextProvider,
            completionProvider: completionProvider,
            presenter: presenter
        )

        await engine.triggerManualSuggestion()
        try await Task.sleep(nanoseconds: 100_000_000)

        var recordedContexts = await completionProvider.recordedContexts()
        XCTAssertEqual(recordedContexts.count, 1)
        XCTAssertNotNil(engine.currentSuggestion)
        XCTAssertEqual(presenter.lastSuggestion?.visibleText, "suggestion")

        await contextProvider.fail(with: .secureOrUnsupportedField)
        let inserter = RecordingTextInserter()
        let outcome = await engine.acceptNextWord(using: inserter)

        XCTAssertEqual(outcome, .passedThrough)
        XCTAssertEqual(inserter.insertedText, "")
        recordedContexts = await completionProvider.recordedContexts()
        XCTAssertEqual(recordedContexts.count, 1)
        XCTAssertNil(engine.currentSuggestion)
        XCTAssertNil(presenter.lastSuggestion)
        XCTAssertEqual(engine.diagnostics.focusFailure?.status, .blocked)
        XCTAssertEqual(engine.diagnostics.lastDecision?.reason, .secureField)
        XCTAssertFalse(engine.diagnostics.menuRows.contains {
            $0.value.localizedCaseInsensitiveContains("normal text")
                || $0.value.localizedCaseInsensitiveContains("suggestion")
        })
        engine.stop()
    }

    func testAutomaticTriggerDoesNotUseLowTrustBufferWhenContextReadFails() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let context = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "ignored"
        )
        let contextProvider = MutableFailingContextProvider(context: context)
        await contextProvider.fail(with: .noReadableText)
        let completionProvider = RecordingContextCompletionProvider(visibleText: "lease continue")
        let fallback = KeystrokeBufferFallback(
            frontmostAppProvider: { app },
            characterTranslator: TestKeystrokeCharacterTranslator(characters: [35: "p"])
        )
        fallback.record(event: .text(keyCode: 35, isSuggestionTrigger: false), currentContext: nil, inputMethodState: .asciiCompatible)
        let engine = SuggestionEngine(
            contextProvider: contextProvider,
            completionProvider: completionProvider,
            presenter: RecordingSuggestionPresenter(),
            keystrokeBufferFallback: fallback
        )

        engine.recordCapturedInputEvent(.text(keyCode: CapturedInputEventAdapter.spaceKeyCode, isSuggestionTrigger: true))
        try await Task.sleep(nanoseconds: 200_000_000)

        let recordedContexts = await completionProvider.recordedContexts()
        XCTAssertEqual(recordedContexts.count, 0)
        XCTAssertNil(engine.currentSuggestion)
        engine.stop()
    }

    func testManualTriggerRequestsMultipleSuggestionsAndAcceptsFirstAlternative() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let context = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please"
        )
        let completionProvider = RecordingMultipleCompletionProvider(visibleTexts: [
            " first option",
            " second option",
            " third option"
        ])
        let presenter = RecordingSuggestionPresenter()
        let engine = SuggestionEngine(
            contextProvider: MutableContextProvider(context: context),
            completionProvider: completionProvider,
            presenter: presenter,
            multiSuggestionEnabled: true
        )

        await engine.triggerManualSuggestion()
        try await Task.sleep(nanoseconds: 100_000_000)

        let requestedCounts = await completionProvider.recordedSuggestionCounts()
        XCTAssertEqual(requestedCounts, [3])
        XCTAssertEqual(engine.currentSuggestion?.alternatives.count, 3)
        XCTAssertEqual(presenter.lastSuggestion?.alternatives.count, 3)
        XCTAssertEqual(presenter.lastSuggestion?.visibleText, " first option")

        let inserter = RecordingTextInserter()
        let outcome = await engine.acceptNextWord(using: inserter)

        XCTAssertEqual(outcome, .accepted)
        XCTAssertEqual(inserter.insertedText, " first option")
        XCTAssertNil(engine.currentSuggestion)
        XCTAssertNil(presenter.lastSuggestion)
        engine.stop()
    }

    func testMultiSuggestionSelectionUpdatesVisibleAlternativeAndStatus() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let context = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please"
        )
        let completionProvider = RecordingMultipleCompletionProvider(visibleTexts: [
            " first option",
            " second option",
            " third option"
        ])
        let presenter = RecordingSuggestionPresenter()
        let engine = SuggestionEngine(
            contextProvider: MutableContextProvider(context: context),
            completionProvider: completionProvider,
            presenter: presenter,
            multiSuggestionEnabled: true
        )

        await engine.triggerManualSuggestion()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertTrue(engine.isMultiSuggestionPopupVisible)
        XCTAssertEqual(engine.statusMessage, "Suggesting in TextEdit; alternative 1 of 3")

        engine.selectNextAlternative()
        XCTAssertEqual(engine.currentSuggestion?.selectedAlternativeIndex, 1)
        XCTAssertEqual(engine.currentSuggestion?.visibleText, " second option")
        XCTAssertEqual(engine.statusMessage, "Alternative 2 of 3 selected")
        XCTAssertEqual(presenter.lastSuggestion?.selectedAlternativeIndex, 1)

        engine.selectPreviousAlternative()
        XCTAssertEqual(engine.currentSuggestion?.selectedAlternativeIndex, 0)
        XCTAssertEqual(engine.currentSuggestion?.visibleText, " first option")
        XCTAssertEqual(engine.statusMessage, "Alternative 1 of 3 selected")
        engine.stop()
    }

    func testAutomaticInlineRequestKeepsSingleSuggestion() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let context = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please ",
            selectedRange: NSRange(location: 7, length: 0),
            caretRect: CGRect(x: 180, y: 110, width: 1, height: 18),
            focusedElementRect: CGRect(x: 100, y: 100, width: 500, height: 40),
            caretGeometryQuality: .directCaret
        )
        let completionProvider = RecordingMultipleCompletionProvider(visibleTexts: [
            "continue this",
            "finish this",
            "expand this"
        ])
        let presenter = RecordingSuggestionPresenter()
        let engine = SuggestionEngine(
            contextProvider: MutableContextProvider(context: context),
            completionProvider: completionProvider,
            presenter: presenter
        )

        engine.recordCapturedInputEvent(.text(keyCode: CapturedInputEventAdapter.spaceKeyCode, isSuggestionTrigger: true))
        try await Task.sleep(nanoseconds: 700_000_000)

        let requestedCounts = await completionProvider.recordedSuggestionCounts()
        XCTAssertEqual(requestedCounts, [1])
        XCTAssertEqual(engine.currentSuggestion?.alternatives.count, 1)
        XCTAssertFalse(engine.currentSuggestion?.hasMultipleAlternatives ?? true)
        XCTAssertEqual(presenter.lastSuggestion?.visibleText, "continue this")
        engine.stop()
    }

    func testDefaultMultiSuggestionSettingKeepsManualTriggerSingleSuggestion() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let context = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please"
        )
        let completionProvider = RecordingMultipleCompletionProvider(visibleTexts: [
            " first option",
            " second option",
            " third option"
        ])
        let presenter = RecordingSuggestionPresenter()
        let engine = SuggestionEngine(
            contextProvider: MutableContextProvider(context: context),
            completionProvider: completionProvider,
            presenter: presenter
        )

        await engine.triggerManualSuggestion()
        try await Task.sleep(nanoseconds: 100_000_000)

        let requestedCounts = await completionProvider.recordedSuggestionCounts()
        XCTAssertEqual(requestedCounts, [1])
        XCTAssertEqual(engine.currentSuggestion?.alternatives.count, 1)
        XCTAssertFalse(engine.currentSuggestion?.hasMultipleAlternatives ?? true)
        XCTAssertEqual(presenter.lastSuggestion?.visibleText, " first option")
        engine.stop()
    }

    func testRemoteBreakerSuppressesAutomaticTriggerButManualBypasses() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let firstContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please "
        )
        let secondContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please retry "
        )
        let contextProvider = MutableContextProvider(context: firstContext)
        let completionProvider = CountingRemoteFailureCompletionProvider(
            error: RemoteCompletionError.connectivity(.timeout)
        )
        let engine = SuggestionEngine(
            contextProvider: contextProvider,
            completionProvider: completionProvider,
            backendHealthMonitor: BackendHealthMonitor(
                circuitBreaker: RemoteCircuitBreaker(
                    failureThreshold: 1,
                    suppressionInterval: 30
                )
            ),
            presenter: RecordingSuggestionPresenter()
        )

        engine.start()
        engine.recordSuggestionTriggerKey(.text(keyCode: CapturedInputEventAdapter.spaceKeyCode, isSuggestionTrigger: true))
        try await Task.sleep(nanoseconds: 700_000_000)

        var callCount = await completionProvider.getCallCount()
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(engine.backendStatusSummary.state, .paused)
        XCTAssertTrue(engine.statusMessage.contains("Paused"))
        XCTAssertEqual(engine.diagnostics.lastDecision?.state, .paused)
        XCTAssertEqual(engine.diagnostics.lastDecision?.reason, .backendCircuitBreaker)

        await contextProvider.updateContext(secondContext)
        engine.recordSuggestionTriggerKey(.text(keyCode: CapturedInputEventAdapter.spaceKeyCode, isSuggestionTrigger: true))
        try await Task.sleep(nanoseconds: 700_000_000)

        callCount = await completionProvider.getCallCount()
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(engine.backendStatusSummary.state, .paused)
        XCTAssertEqual(engine.diagnostics.lastDecision?.state, .paused)
        XCTAssertEqual(engine.diagnostics.lastDecision?.reason, .backendCircuitBreaker)

        await engine.triggerManualSuggestion()
        try await Task.sleep(nanoseconds: 150_000_000)

        callCount = await completionProvider.getCallCount()
        XCTAssertEqual(callCount, 2)
        engine.stop()
    }

    func testBackendProbeResultUpdatesBackendHealthSummary() {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let context = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please "
        )
        let completionProvider = CountingCompletionProvider(
            suggestion: Suggestion(
                baseContextID: context.id,
                visibleText: "continue this",
                latencyMs: 25
            )
        )
        let engine = SuggestionEngine(
            contextProvider: MutableContextProvider(context: context),
            completionProvider: completionProvider,
            presenter: RecordingSuggestionPresenter()
        )

        engine.recordBackendProbeResult(RemoteBackendProbeResult(
            status: .failed,
            message: "Remote backend timed out.",
            issue: .timeout
        ))

        XCTAssertEqual(engine.backendStatusSummary.state, .disconnected)
        XCTAssertEqual(engine.backendStatusSummary.issue, .timeout)
        XCTAssertEqual(engine.statusMessage, "Remote backend timed out.")

        engine.recordBackendProbeResult(RemoteBackendProbeResult(
            status: .connected,
            message: "Connected"
        ))

        XCTAssertEqual(engine.backendStatusSummary.state, .connected)
        XCTAssertEqual(engine.statusMessage, "Connected")
    }

    func testCompletionProviderUpdateClearsSuggestionSessionForModelSwitch() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let context = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please"
        )
        let presenter = RecordingSuggestionPresenter()
        let engine = SuggestionEngine(
            contextProvider: MutableContextProvider(context: context),
            completionProvider: CountingCompletionProvider(
                suggestion: Suggestion(
                    baseContextID: context.id,
                    visibleText: " continue this",
                    latencyMs: 25
                )
            ),
            presenter: presenter
        )

        await engine.triggerManualSuggestion()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNotNil(engine.currentSuggestion)
        XCTAssertNotNil(presenter.lastSuggestion)

        engine.updateCompletionProvider(
            CountingCompletionProvider(
                suggestion: Suggestion(
                    baseContextID: context.id,
                    visibleText: " switched model",
                    latencyMs: 12
                )
            ),
            status: "Local model updated",
            reason: .runtimeModelSwitch
        )

        XCTAssertNil(engine.currentSuggestion)
        XCTAssertNil(engine.currentContext)
        XCTAssertNil(presenter.lastSuggestion)
        XCTAssertEqual(engine.diagnostics.staleDiscardReason, "runtime-model-switch")
        XCTAssertEqual(engine.statusMessage, "Local model updated")
    }

    func testBackendSwitchCancelsInFlightGenerationAndShutsDownOldProvider() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let context = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please "
        )
        let oldProvider = LifecycleCompletionProvider(
            visibleText: "old completion",
            delayNanoseconds: 700_000_000
        )
        let presenter = RecordingSuggestionPresenter()
        let engine = SuggestionEngine(
            contextProvider: MutableContextProvider(context: context),
            completionProvider: oldProvider,
            presenter: presenter
        )

        engine.start()
        engine.recordSuggestionTriggerKey(.text(keyCode: CapturedInputEventAdapter.spaceKeyCode, isSuggestionTrigger: true))
        await oldProvider.waitForCallCount(1)

        engine.updateCompletionProvider(
            CountingCompletionProvider(
                suggestion: Suggestion(
                    baseContextID: context.id,
                    visibleText: "new completion",
                    latencyMs: 12
                )
            ),
            status: "Backend updated",
            reason: .backendSwitch
        )
        await oldProvider.waitForPrepareCount(1)

        XCTAssertNil(engine.currentSuggestion)
        XCTAssertNil(engine.currentContext)
        XCTAssertNil(presenter.lastSuggestion)
        XCTAssertEqual(engine.diagnostics.staleDiscardReason, "backend-switch")
        XCTAssertEqual(engine.statusMessage, "Backend updated")
        try await Task.sleep(nanoseconds: 850_000_000)

        XCTAssertNil(engine.currentSuggestion)
        XCTAssertNil(presenter.lastSuggestion)
        XCTAssertEqual(engine.diagnostics.staleDiscardReason, "backend-switch")
        engine.stop()
    }

    func testDismissSuggestionPausesUntilTextMutation() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let initialContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please "
        )
        let changedContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please continue "
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
        let callCountAfterFirstSuggestion = await completionProvider.getCallCount()
        XCTAssertEqual(callCountAfterFirstSuggestion, 1)
        XCTAssertNotNil(presenter.lastSuggestion)

        engine.dismissSuggestionUntilTextMutation()
        try await Task.sleep(nanoseconds: 700_000_000)
        let callCountAfterDismissal = await completionProvider.getCallCount()
        XCTAssertEqual(callCountAfterDismissal, 1)
        XCTAssertNil(presenter.lastSuggestion)

        await contextProvider.updateContext(changedContext)
        engine.recordSuggestionTriggerKey(.text(keyCode: CapturedInputEventAdapter.spaceKeyCode, isSuggestionTrigger: true))
        try await Task.sleep(nanoseconds: 700_000_000)
        let callCountAfterMutation = await completionProvider.getCallCount()
        XCTAssertEqual(callCountAfterMutation, 2)
        engine.stop()
    }

    func testDisablingAutocompleteCancelsAndSuppressesManualTrigger() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let context = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please "
        )
        let completionProvider = CountingCompletionProvider(
            suggestion: Suggestion(
                baseContextID: context.id,
                visibleText: "continue this",
                latencyMs: 25
            )
        )
        let presenter = RecordingSuggestionPresenter()
        let engine = SuggestionEngine(
            contextProvider: MutableContextProvider(context: context),
            completionProvider: completionProvider,
            presenter: presenter
        )

        engine.setAutocompleteEnabled(false)
        await engine.triggerManualSuggestion()
        try await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertFalse(engine.isAutocompleteEnabled)
        XCTAssertEqual(engine.statusMessage, "AutoComp disabled")
        let callCount = await completionProvider.getCallCount()
        XCTAssertEqual(callCount, 0)
        XCTAssertNil(presenter.lastSuggestion)
    }

    func testManualOnlyCompatibilitySuppressesAutomaticButAllowsManualTrigger() async throws {
        let app = AppIdentity(bundleID: "com.apple.mail", displayName: "Mail", processID: 1)
        let context = TextContext(
            app: app,
            focusedElementID: "mail-compose",
            textBeforeCursor: "Please "
        )
        let completionProvider = CountingCompletionProvider(
            suggestion: Suggestion(
                baseContextID: context.id,
                visibleText: "continue this",
                latencyMs: 25
            )
        )
        let presenter = RecordingSuggestionPresenter()
        let engine = SuggestionEngine(
            contextProvider: MutableContextProvider(context: context),
            completionProvider: completionProvider,
            presenter: presenter
        )

        engine.start()
        try await Task.sleep(nanoseconds: 700_000_000)

        var callCount = await completionProvider.getCallCount()
        XCTAssertEqual(callCount, 0)
        XCTAssertNil(presenter.lastSuggestion)
        XCTAssertEqual(engine.statusMessage, "Manual-only waiting for trigger")

        await engine.triggerManualSuggestion()
        try await Task.sleep(nanoseconds: 150_000_000)

        callCount = await completionProvider.getCallCount()
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(presenter.lastSuggestion?.visibleText, "continue this")
        engine.stop()
    }

    func testChatAcceptanceBlocksReturnBearingSuggestionBeforeInsertion() async throws {
        let app = AppIdentity(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack", processID: 1)
        let context = TextContext(
            app: app,
            focusedElementID: "slack-composer",
            stableFieldIdentity: StableFieldIdentity(app: app, role: "AXTextArea"),
            textBeforeCursor: "Please ",
            selectedRange: NSRange(location: 7, length: 0)
        )
        let contextProvider = MutableContextProvider(context: context)
        let completionProvider = CountingCompletionProvider(
            suggestion: Suggestion(
                baseContextID: context.id,
                visibleText: "line one\nline two",
                latencyMs: 25
            )
        )
        let presenter = RecordingSuggestionPresenter()
        let engine = SuggestionEngine(
            contextProvider: contextProvider,
            completionProvider: completionProvider,
            presenter: presenter
        )

        await engine.triggerManualSuggestion()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(presenter.lastSuggestion?.visibleText, "line one\nline two")

        let inserter = RecordingTextInserter()
        let outcome = await engine.acceptAll(using: inserter)

        XCTAssertEqual(outcome, .passedThrough)
        XCTAssertEqual(inserter.insertedText, "")
        XCTAssertNil(engine.currentSuggestion)
        XCTAssertNil(presenter.lastSuggestion)
        XCTAssertEqual(engine.statusMessage, "Risky host app blocked")
        XCTAssertEqual(engine.diagnostics.lastDecision?.summary, "blocked: blocked-risky-host-app")
        engine.stop()
    }

    func testRiskyHostAcceptanceBlocksUnclearEditableTarget() async throws {
        let app = AppIdentity(bundleID: "com.microsoft.VSCode", displayName: "VS Code", processID: 1)
        let context = TextContext(
            app: app,
            focusedElementID: "unknown-pane",
            textBeforeCursor: "Please "
        )
        let contextProvider = MutableContextProvider(context: context)
        let completionProvider = CountingCompletionProvider(
            suggestion: Suggestion(
                baseContextID: context.id,
                visibleText: "continue this",
                latencyMs: 25
            )
        )
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "RiskyHostAcceptance-\(UUID().uuidString)"))
        let compatibilitySettings = CompatibilitySettingsStore(defaults: defaults)
        compatibilitySettings.setMode(.manualOnly, for: "com.microsoft.VSCode")
        let presenter = RecordingSuggestionPresenter()
        let engine = SuggestionEngine(
            contextProvider: contextProvider,
            completionProvider: completionProvider,
            presenter: presenter,
            compatibilitySettings: compatibilitySettings
        )

        await engine.triggerManualSuggestion()
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(presenter.lastSuggestion?.visibleText, "continue this")

        let inserter = RecordingTextInserter()
        let outcome = await engine.acceptNextWord(using: inserter)

        XCTAssertEqual(outcome, .passedThrough)
        XCTAssertEqual(inserter.insertedText, "")
        XCTAssertNil(engine.currentSuggestion)
        XCTAssertNil(presenter.lastSuggestion)
        XCTAssertEqual(engine.statusMessage, "Risky host app blocked")
        XCTAssertEqual(engine.diagnostics.lastDecision?.summary, "blocked: blocked-risky-host-app")
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

    func testProductivityMetricsRecordsLatencyAcceptanceAndDismissalEvents() async throws {
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
        let metrics = RecordingProductivityMetrics()
        let engine = SuggestionEngine(
            contextProvider: contextProvider,
            completionProvider: completionProvider,
            presenter: RecordingSuggestionPresenter(),
            productivityMetrics: metrics
        )

        engine.recordCapturedInputEvent(.text(keyCode: CapturedInputEventAdapter.spaceKeyCode, isSuggestionTrigger: true))
        try await Task.sleep(nanoseconds: 700_000_000)

        XCTAssertEqual(metrics.completionLatencyReports.count, 1)
        XCTAssertNotNil(metrics.completionLatencyReports.first?.axCaptureMs)
        XCTAssertNotNil(metrics.completionLatencyReports.first?.debounceMs)
        XCTAssertNotNil(metrics.completionLatencyReports.first?.backendMs)

        let inserter = RecordingTextInserter()
        await engine.acceptNextWord(using: inserter)
        engine.dismissSuggestionUntilTextMutation()

        XCTAssertEqual(metrics.acceptedTexts, ["complete "])
        XCTAssertEqual(metrics.dismissedSuggestions, 1)
        XCTAssertEqual(metrics.insertionLatencies.count, 1)
    }

    func testAcceptNextWordPassesThroughWhenLiveContextChangedTargets() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let initialContext = TextContext(
            app: app,
            focusedElementID: "textedit-field-a",
            textBeforeCursor: "Please ",
            selectedRange: NSRange(location: 7, length: 0),
            focusedElementRect: CGRect(x: 100, y: 100, width: 400, height: 40)
        )
        let changedContext = TextContext(
            app: app,
            focusedElementID: "textedit-field-b",
            textBeforeCursor: "Other ",
            selectedRange: NSRange(location: 6, length: 0),
            focusedElementRect: CGRect(x: 100, y: 180, width: 400, height: 40)
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
        let engine = SuggestionEngine(
            contextProvider: contextProvider,
            completionProvider: completionProvider,
            presenter: presenter
        )

        engine.recordCapturedInputEvent(.text(keyCode: CapturedInputEventAdapter.spaceKeyCode, isSuggestionTrigger: true))
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(presenter.lastSuggestion?.visibleText, "complete thought")

        await contextProvider.updateContext(changedContext)
        let inserter = RecordingTextInserter()
        let outcome = await engine.acceptNextWord(using: inserter)

        XCTAssertEqual(outcome, .passedThrough)
        XCTAssertEqual(inserter.insertedText, "")
        XCTAssertNil(engine.currentSuggestion)
        XCTAssertNil(presenter.lastSuggestion)
        XCTAssertEqual(engine.statusMessage, "Suggestion unavailable")
        let callCount = await completionProvider.getCallCount()
        XCTAssertEqual(callCount, 1)
        engine.stop()
    }

    func testAcceptNextWordPassesThroughWhenLiveTextDivergesFromSuggestionSession() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let initialContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please ",
            selectedRange: NSRange(location: 7, length: 0)
        )
        let divergentContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please x",
            selectedRange: NSRange(location: 8, length: 0)
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
        let engine = SuggestionEngine(
            contextProvider: contextProvider,
            completionProvider: completionProvider,
            presenter: presenter
        )

        engine.recordCapturedInputEvent(.text(keyCode: CapturedInputEventAdapter.spaceKeyCode, isSuggestionTrigger: true))
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(presenter.lastSuggestion?.visibleText, "complete thought")

        await contextProvider.updateContext(divergentContext)
        let inserter = RecordingTextInserter()
        let outcome = await engine.acceptNextWord(using: inserter)

        XCTAssertEqual(outcome, .passedThrough)
        XCTAssertEqual(inserter.insertedText, "")
        XCTAssertNil(engine.currentSuggestion)
        XCTAssertNil(presenter.lastSuggestion)
        XCTAssertEqual(engine.statusMessage, "Suggestion unavailable")
        let callCount = await completionProvider.getCallCount()
        XCTAssertEqual(callCount, 1)
        engine.stop()
    }

    func testAcceptAllPassesThroughWithoutInsertionWhenLiveContextHasSelection() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let initialContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please ",
            selectedRange: NSRange(location: 7, length: 0)
        )
        let selectedContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please ",
            selectedText: "ea",
            selectedRange: NSRange(location: 2, length: 2)
        )
        let contextProvider = MutableContextProvider(context: initialContext)
        let completionProvider = CountingCompletionProvider(
            suggestion: Suggestion(
                baseContextID: initialContext.id,
                visibleText: "finish the sentence",
                latencyMs: 25
            )
        )
        let presenter = RecordingSuggestionPresenter()
        let engine = SuggestionEngine(
            contextProvider: contextProvider,
            completionProvider: completionProvider,
            presenter: presenter
        )

        engine.recordCapturedInputEvent(.text(keyCode: CapturedInputEventAdapter.spaceKeyCode, isSuggestionTrigger: true))
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(presenter.lastSuggestion?.visibleText, "finish the sentence")

        await contextProvider.updateContext(selectedContext)
        let inserter = RecordingTextInserter()
        let outcome = await engine.acceptAll(using: inserter)

        XCTAssertEqual(outcome, .passedThrough)
        XCTAssertEqual(inserter.insertedText, "")
        XCTAssertNil(engine.currentSuggestion)
        XCTAssertNil(presenter.lastSuggestion)
        XCTAssertEqual(engine.statusMessage, "Suggestion unavailable")
        let callCount = await completionProvider.getCallCount()
        XCTAssertEqual(callCount, 1)
        engine.stop()
    }

    func testVisualContextProviderSnapshotFlowsIntoCompletionProvider() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AutoCompVisualFlow-\(UUID().uuidString)"))
        let privacyStore = PrivacySettingsStore(defaults: defaults, key: "privacy")
        try privacyStore.save(PrivacySettings(screenContextEnabled: true))
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let stableFieldIdentity = StableFieldIdentity(
            app: app,
            role: "AXTextArea",
            focusedElementFrame: CGRect(x: 100, y: 100, width: 500, height: 40),
            focusChangeSequence: 3
        )
        let caretRect = CGRect(x: 180, y: 110, width: 1, height: 18)
        let focusedElementRect = CGRect(x: 100, y: 100, width: 500, height: 40)
        let initialContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            stableFieldIdentity: stableFieldIdentity,
            textBeforeCursor: "Please ",
            caretRect: caretRect,
            focusedElementRect: focusedElementRect
        )
        let visualContext = VisualContextSnapshot(summary: "Visible title Budget Review")
        let visualContextProvider = StaticVisualContextProvider(snapshot: visualContext)
        let completionProvider = RecordingVisualContextCompletionProvider()
        let engine = SuggestionEngine(
            contextProvider: MutableContextProvider(context: initialContext),
            completionProvider: completionProvider,
            visualContextProvider: visualContextProvider,
            presenter: RecordingSuggestionPresenter(),
            privacyStore: privacyStore
        )

        engine.start()
        engine.recordSuggestionTriggerKey(.text(keyCode: CapturedInputEventAdapter.spaceKeyCode, isSuggestionTrigger: true))
        try await Task.sleep(nanoseconds: 900_000_000)

        let recordedVisualContext = await completionProvider.recordedVisualContext()
        let recordedContext = await completionProvider.recordedContext()
        let recordedPrivacySettings = await completionProvider.recordedPrivacySettings()
        let recordedStableFieldIdentity = await visualContextProvider.recordedStableFieldIdentity()
        XCTAssertEqual(recordedVisualContext, visualContext)
        XCTAssertEqual(recordedContext?.caretRect, caretRect)
        XCTAssertEqual(recordedContext?.focusedElementRect, focusedElementRect)
        XCTAssertEqual(recordedStableFieldIdentity, stableFieldIdentity)
        XCTAssertEqual(recordedPrivacySettings?.screenContextEnabled, true)
        engine.stop()
    }

    func testReadyVisualContextIsDiscardedWhenStableFieldChangesBeforeCompletion() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AutoCompVisualStale-\(UUID().uuidString)"))
        let privacyStore = PrivacySettingsStore(defaults: defaults, key: "privacy")
        try privacyStore.save(PrivacySettings(screenContextEnabled: true))
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let firstIdentity = StableFieldIdentity(
            app: app,
            role: "AXTextArea",
            focusedElementFrame: CGRect(x: 100, y: 100, width: 500, height: 40),
            focusChangeSequence: 3
        )
        let secondIdentity = StableFieldIdentity(
            app: app,
            role: "AXTextArea",
            focusedElementFrame: CGRect(x: 100, y: 180, width: 500, height: 40),
            focusChangeSequence: 4
        )
        let firstContext = TextContext(
            app: app,
            focusedElementID: "textedit-field-a",
            stableFieldIdentity: firstIdentity,
            textBeforeCursor: "Please "
        )
        let secondContext = TextContext(
            app: app,
            focusedElementID: "textedit-field-b",
            stableFieldIdentity: secondIdentity,
            textBeforeCursor: "Please "
        )
        let contextProvider = MutableContextProvider(context: firstContext)
        let visualContextProvider = SuspendedStableVisualContextProvider()
        let completionProvider = CountingCompletionProvider(
            suggestion: Suggestion(
                baseContextID: firstContext.id,
                visibleText: "continue this",
                latencyMs: 25
            )
        )
        let presenter = RecordingSuggestionPresenter()
        let engine = SuggestionEngine(
            contextProvider: contextProvider,
            completionProvider: completionProvider,
            visualContextProvider: visualContextProvider,
            presenter: presenter,
            privacyStore: privacyStore
        )

        engine.start()
        engine.recordSuggestionTriggerKey(.text(keyCode: CapturedInputEventAdapter.spaceKeyCode, isSuggestionTrigger: true))
        await visualContextProvider.waitForPendingRequestCount(1)
        await contextProvider.updateContext(secondContext)
        await visualContextProvider.resumeNext(with: VisualContextSnapshot(
            summary: "Visible title Budget Review",
            stableFieldIdentity: firstIdentity
        ))
        try await Task.sleep(nanoseconds: 400_000_000)

        let callCount = await completionProvider.getCallCount()
        let recordedStableFieldIdentities = await visualContextProvider.recordedStableFieldIdentities()
        XCTAssertEqual(callCount, 0)
        XCTAssertNil(presenter.lastSuggestion)
        XCTAssertEqual(recordedStableFieldIdentities, [firstIdentity])
        engine.stop()
    }

    func testBackendSwitchClearsPendingVisualContextBeforeCallingOldProvider() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AutoCompVisualBackendSwitch-\(UUID().uuidString)"))
        let privacyStore = PrivacySettingsStore(defaults: defaults, key: "privacy")
        try privacyStore.save(PrivacySettings(screenContextEnabled: true))
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let stableFieldIdentity = StableFieldIdentity(
            app: app,
            role: "AXTextArea",
            focusedElementFrame: CGRect(x: 100, y: 100, width: 500, height: 40),
            focusChangeSequence: 3
        )
        let context = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            stableFieldIdentity: stableFieldIdentity,
            textBeforeCursor: "Please "
        )
        let visualContextProvider = ClearingSuspendedStableVisualContextProvider()
        let oldProvider = CountingCompletionProvider(
            suggestion: Suggestion(
                baseContextID: context.id,
                visibleText: "old completion",
                latencyMs: 25
            )
        )
        let presenter = RecordingSuggestionPresenter()
        let engine = SuggestionEngine(
            contextProvider: MutableContextProvider(context: context),
            completionProvider: oldProvider,
            visualContextProvider: visualContextProvider,
            presenter: presenter,
            privacyStore: privacyStore
        )

        engine.start()
        engine.recordSuggestionTriggerKey(.text(keyCode: CapturedInputEventAdapter.spaceKeyCode, isSuggestionTrigger: true))
        await visualContextProvider.waitForPendingRequestCount(1)

        engine.updateCompletionProvider(
            CountingCompletionProvider(
                suggestion: Suggestion(
                    baseContextID: context.id,
                    visibleText: "new completion",
                    latencyMs: 12
                )
            ),
            status: "Backend updated",
            reason: .backendSwitch
        )
        await visualContextProvider.waitForClearCount(1)
        try await Task.sleep(nanoseconds: 400_000_000)

        let callCount = await oldProvider.getCallCount()
        XCTAssertEqual(callCount, 0)
        XCTAssertNil(engine.currentSuggestion)
        XCTAssertNil(presenter.lastSuggestion)
        XCTAssertEqual(engine.diagnostics.staleDiscardReason, "backend-switch")
        engine.stop()
    }

    func testClipboardContextProviderSnapshotFlowsIntoCompletionProvider() async throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AutoCompClipboardFlow-\(UUID().uuidString)"))
        let privacyStore = PrivacySettingsStore(defaults: defaults, key: "privacy")
        try privacyStore.save(PrivacySettings(clipboardContextEnabled: true))
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let initialContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please "
        )
        let clipboardContext = ClipboardContextSnapshot(
            summary: "Launch plan",
            status: .included,
            captureSources: [.clipboard]
        )
        let completionProvider = RecordingClipboardContextCompletionProvider()
        let engine = SuggestionEngine(
            contextProvider: MutableContextProvider(context: initialContext),
            completionProvider: completionProvider,
            clipboardContextProvider: StaticClipboardContextProvider(snapshot: clipboardContext),
            presenter: RecordingSuggestionPresenter(),
            privacyStore: privacyStore
        )

        engine.start()
        engine.recordSuggestionTriggerKey(.text(keyCode: CapturedInputEventAdapter.spaceKeyCode, isSuggestionTrigger: true))
        try await Task.sleep(nanoseconds: 900_000_000)

        let recordedClipboardContext = await completionProvider.recordedClipboardContext()
        let recordedPrivacySettings = await completionProvider.recordedPrivacySettings()
        XCTAssertEqual(recordedClipboardContext, clipboardContext)
        XCTAssertEqual(recordedPrivacySettings?.clipboardContextEnabled, true)
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

    func testDiagnosticsRecordCompletionSuccessWithPrivacyAllowedOutputSummaries() async throws {
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
        XCTAssertEqual(
            engine.diagnostics.output.rawPreview,
            AutoCompLogger.redactedSummary(for: "Completion:\n continue this").description
        )
        XCTAssertEqual(
            engine.diagnostics.output.normalizedPreview,
            AutoCompLogger.redactedSummary(for: "continue this").description
        )
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

    func testDebugOptInWritesAutocompleteArtifactOnSuccess() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("autocomp-autocomplete-debug-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let artifactStore = DebugArtifactStore(directory: directory)
        let logger = SuggestionDebugLogger(artifactStore: artifactStore)
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let context = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please "
        )
        let engine = SuggestionEngine(
            contextProvider: MutableContextProvider(context: context),
            completionProvider: RawSuggestionCompletionProvider(
                rawText: "Completion:\n continue this",
                visibleText: " continue this"
            ),
            presenter: RecordingSuggestionPresenter(),
            suggestionDebugLogger: logger,
            debugOptionsProvider: { AutoCompDebugOptions(localDebugOptIn: true) }
        )

        engine.start()
        engine.recordSuggestionTriggerKey(.text(keyCode: CapturedInputEventAdapter.spaceKeyCode, isSuggestionTrigger: true))
        try await Task.sleep(nanoseconds: 900_000_000)

        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(urls.count, 1)
        let body = try String(contentsOf: urls[0], encoding: .utf8)
        XCTAssertTrue(body.contains("Outcome: published"))
        XCTAssertTrue(body.contains("Prompt:"))
        XCTAssertTrue(body.contains("Please"))
        XCTAssertTrue(body.contains("Suggestions:"))
        XCTAssertTrue(body.contains("Completion:"))
        XCTAssertTrue(body.contains("continue this"))
        engine.stop()
    }

    func testDebugOptInWritesAutocompleteArtifactOnFailure() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("autocomp-autocomplete-debug-\(UUID().uuidString)", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let artifactStore = DebugArtifactStore(directory: directory)
        let logger = SuggestionDebugLogger(artifactStore: artifactStore)
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let context = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please "
        )
        let engine = SuggestionEngine(
            contextProvider: MutableContextProvider(context: context),
            completionProvider: FailingCompletionProvider(),
            presenter: RecordingSuggestionPresenter(),
            suggestionDebugLogger: logger,
            debugOptionsProvider: { AutoCompDebugOptions(localDebugOptIn: true) }
        )

        engine.start()
        engine.recordSuggestionTriggerKey(.text(keyCode: CapturedInputEventAdapter.spaceKeyCode, isSuggestionTrigger: true))
        try await Task.sleep(nanoseconds: 900_000_000)

        let urls = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertEqual(urls.count, 1)
        let body = try String(contentsOf: urls[0], encoding: .utf8)
        XCTAssertTrue(body.contains("Outcome: failed"))
        XCTAssertTrue(body.contains("Error: Test completion failed."))
        XCTAssertTrue(body.contains("Prompt:"))
        XCTAssertTrue(body.contains("Please"))
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

    func testGoogleDocsCanPublishConsecutiveSuggestionsWhenUserKeepsTyping() async throws {
        let app = AppIdentity(bundleID: "com.google.Chrome", displayName: "Google Chrome", processID: 1)
        let initialContext = googleDocsContext(
            app: app,
            focusedElementID: "docs-field-a",
            textBeforeCursor: "Primeira"
        )
        let firstTrigger = googleDocsContext(
            app: app,
            focusedElementID: "docs-field-b",
            textBeforeCursor: "Primeira ",
            caretX: 510
        )
        let secondTrigger = googleDocsContext(
            app: app,
            focusedElementID: "docs-field-c",
            textBeforeCursor: "Primeira segunda ",
            caretX: 590
        )
        let thirdTrigger = googleDocsContext(
            app: app,
            focusedElementID: "docs-field-d",
            textBeforeCursor: "Primeira segunda terceira ",
            caretX: 690
        )
        let contextProvider = MutableContextProvider(context: initialContext)
        let completionProvider = CountingCompletionProvider(
            suggestion: Suggestion(
                baseContextID: initialContext.id,
                visibleText: "consegue me ajudar com isso",
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

        await contextProvider.updateContext(firstTrigger)
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(presenter.lastSuggestion?.visibleText, "consegue me ajudar com isso")

        await contextProvider.updateContext(secondTrigger)
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(presenter.lastSuggestion?.visibleText, "consegue me ajudar com isso")
        XCTAssertEqual(presenter.lastContext?.textBeforeCursor, "Primeira segunda ")

        await contextProvider.updateContext(thirdTrigger)
        try await Task.sleep(nanoseconds: 700_000_000)
        XCTAssertEqual(presenter.lastSuggestion?.visibleText, "consegue me ajudar com isso")
        XCTAssertEqual(presenter.lastContext?.textBeforeCursor, "Primeira segunda terceira ")

        let callCount = await completionProvider.getCallCount()
        XCTAssertEqual(callCount, 3)
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

    func testCapturedTypedThroughOneCharacterAdvancesPublishedSuggestion() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let publishedContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please "
        )
        let typedThroughContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please c"
        )
        let contextProvider = MutableContextProvider(context: publishedContext)
        let completionProvider = CountingCompletionProvider(
            suggestion: Suggestion(
                baseContextID: publishedContext.id,
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

        engine.recordCapturedInputEvent(.text(keyCode: CapturedInputEventAdapter.spaceKeyCode, isSuggestionTrigger: true))
        try await Task.sleep(nanoseconds: 700_000_000)
        await contextProvider.updateContext(typedThroughContext)
        engine.recordCapturedInputEvent(.text(keyCode: 8, isSuggestionTrigger: false))
        try await Task.sleep(nanoseconds: 350_000_000)

        XCTAssertEqual(engine.statusMessage, "Continuing accepted suggestion")
        XCTAssertEqual(engine.currentSuggestion?.visibleText, "ontinue this suggestion")
        XCTAssertEqual(presenter.lastSuggestion?.visibleText, "ontinue this suggestion")
        let callCount = await completionProvider.getCallCount()
        XCTAssertEqual(callCount, 1)
        engine.stop()
    }

    func testCapturedTypedThroughMultipleCharactersAdvancesPublishedSuggestion() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let publishedContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please "
        )
        let typedThroughContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please cont"
        )
        let contextProvider = MutableContextProvider(context: publishedContext)
        let completionProvider = CountingCompletionProvider(
            suggestion: Suggestion(
                baseContextID: publishedContext.id,
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

        engine.recordCapturedInputEvent(.text(keyCode: CapturedInputEventAdapter.spaceKeyCode, isSuggestionTrigger: true))
        try await Task.sleep(nanoseconds: 700_000_000)
        await contextProvider.updateContext(typedThroughContext)
        engine.recordCapturedInputEvent(.text(keyCode: 17, isSuggestionTrigger: false))
        try await Task.sleep(nanoseconds: 350_000_000)

        XCTAssertEqual(engine.statusMessage, "Continuing accepted suggestion")
        XCTAssertEqual(engine.currentSuggestion?.visibleText, "inue this suggestion")
        XCTAssertEqual(presenter.lastSuggestion?.visibleText, "inue this suggestion")
        let callCount = await completionProvider.getCallCount()
        XCTAssertEqual(callCount, 1)
        engine.stop()
    }

    func testCapturedTypedThroughExhaustionSchedulesNextPrediction() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let publishedContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please "
        )
        let exhaustedContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please done "
        )
        let contextProvider = MutableContextProvider(context: publishedContext)
        let completionProvider = CountingCompletionProvider(
            suggestion: Suggestion(
                baseContextID: publishedContext.id,
                visibleText: "done ",
                latencyMs: 25
            )
        )
        let presenter = RecordingSuggestionPresenter()
        let engine = SuggestionEngine(
            contextProvider: contextProvider,
            completionProvider: completionProvider,
            presenter: presenter
        )

        engine.recordCapturedInputEvent(.text(keyCode: CapturedInputEventAdapter.spaceKeyCode, isSuggestionTrigger: true))
        try await Task.sleep(nanoseconds: 700_000_000)
        await contextProvider.updateContext(exhaustedContext)
        engine.recordCapturedInputEvent(.text(keyCode: CapturedInputEventAdapter.spaceKeyCode, isSuggestionTrigger: true))
        try await Task.sleep(nanoseconds: 900_000_000)

        let callCount = await completionProvider.getCallCount()
        XCTAssertEqual(callCount, 2)
        XCTAssertEqual(engine.currentContext?.textBeforeCursor, "Please done ")
        XCTAssertEqual(presenter.lastSuggestion?.visibleText, "done ")
        engine.stop()
    }

    func testCapturedTypedThroughDivergenceClearsPublishedSuggestion() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let publishedContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please "
        )
        let divergentContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please x"
        )
        let contextProvider = MutableContextProvider(context: publishedContext)
        let completionProvider = CountingCompletionProvider(
            suggestion: Suggestion(
                baseContextID: publishedContext.id,
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

        engine.recordCapturedInputEvent(.text(keyCode: CapturedInputEventAdapter.spaceKeyCode, isSuggestionTrigger: true))
        try await Task.sleep(nanoseconds: 700_000_000)
        await contextProvider.updateContext(divergentContext)
        engine.recordCapturedInputEvent(.text(keyCode: 7, isSuggestionTrigger: false))
        try await Task.sleep(nanoseconds: 350_000_000)

        XCTAssertNil(engine.currentSuggestion)
        XCTAssertNil(presenter.lastSuggestion)
        let callCount = await completionProvider.getCallCount()
        XCTAssertEqual(callCount, 1)
        engine.stop()
    }

    func testCapturedTypedThroughFieldChangeClearsPublishedSuggestion() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let publishedContext = TextContext(
            app: app,
            focusedElementID: "textedit-field-a",
            textBeforeCursor: "Please ",
            focusedElementRect: CGRect(x: 100, y: 100, width: 400, height: 40)
        )
        let changedFieldContext = TextContext(
            app: app,
            focusedElementID: "textedit-field-b",
            textBeforeCursor: "Please c",
            focusedElementRect: CGRect(x: 100, y: 180, width: 400, height: 40)
        )
        let contextProvider = MutableContextProvider(context: publishedContext)
        let completionProvider = CountingCompletionProvider(
            suggestion: Suggestion(
                baseContextID: publishedContext.id,
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

        engine.recordCapturedInputEvent(.text(keyCode: CapturedInputEventAdapter.spaceKeyCode, isSuggestionTrigger: true))
        try await Task.sleep(nanoseconds: 700_000_000)
        await contextProvider.updateContext(changedFieldContext)
        engine.recordCapturedInputEvent(.text(keyCode: 8, isSuggestionTrigger: false))
        try await Task.sleep(nanoseconds: 350_000_000)

        XCTAssertNil(engine.currentSuggestion)
        XCTAssertNil(presenter.lastSuggestion)
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

    func testRepeatedTabThroughFinalWordDoesNotRequestNewCompletionUntilUserTypesDifferentText() async throws {
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
        let finalAcceptedEchoContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please keep this"
        )
        let divergentContext = TextContext(
            app: app,
            focusedElementID: "textedit-field",
            textBeforeCursor: "Please keep this typed "
        )
        let contextProvider = MutableContextProvider(context: initialContext)
        let completionProvider = CountingCompletionProvider(
            suggestion: Suggestion(
                baseContextID: initialContext.id,
                visibleText: "keep this",
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
        await contextProvider.updateContext(firstAcceptedEchoContext)
        try await Task.sleep(nanoseconds: 500_000_000)
        await engine.acceptNextWord(using: inserter)
        XCTAssertNil(engine.currentSuggestion)

        await contextProvider.updateContext(finalAcceptedEchoContext)
        try await Task.sleep(nanoseconds: 9_000_000_000)
        let callCountAfterFinalAcceptanceSettled = await completionProvider.getCallCount()
        XCTAssertEqual(callCountAfterFinalAcceptanceSettled, 1)

        await contextProvider.updateContext(divergentContext)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let callCountAfterUserDiverged = await completionProvider.getCallCount()
        XCTAssertEqual(callCountAfterUserDiverged, 2)
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

private func googleDocsContext(
    app: AppIdentity,
    focusedElementID: String,
    textBeforeCursor: String,
    caretX: CGFloat = 450
) -> TextContext {
    TextContext(
        app: app,
        domain: "docs.google.com",
        focusedElementID: focusedElementID,
        textBeforeCursor: textBeforeCursor,
        selectedRange: NSRange(location: (textBeforeCursor as NSString).length, length: 0),
        caretRect: CGRect(x: caretX, y: 381, width: 1, height: 16),
        focusedElementRect: CGRect(x: caretX, y: 381, width: 626, height: 1)
    )
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

private actor PromptCacheStatsCompletionProvider: CompletionProvider, PromptCacheReportingCompletionProvider {
    private let suggestion: Suggestion
    private let stats: LlamaPromptCacheStats
    private var resetCount = 0

    init(suggestion: Suggestion, stats: LlamaPromptCacheStats) {
        self.suggestion = suggestion
        self.stats = stats
    }

    func complete(context: TextContext) async throws -> Suggestion {
        Suggestion(
            baseContextID: context.id,
            visibleText: suggestion.visibleText,
            latencyMs: suggestion.latencyMs
        )
    }

    func resetPromptCache() async {
        resetCount += 1
    }

    func promptCacheStats() async -> LlamaPromptCacheStats? {
        stats
    }
}

private actor RecordingContextCompletionProvider: CompletionProvider {
    private let visibleText: String
    private var contexts: [TextContext] = []

    init(visibleText: String) {
        self.visibleText = visibleText
    }

    func recordedContexts() -> [TextContext] {
        contexts
    }

    func complete(context: TextContext) async throws -> Suggestion {
        contexts.append(context)
        return Suggestion(
            baseContextID: context.id,
            visibleText: visibleText,
            latencyMs: 12
        )
    }
}

private actor RecordingMultipleCompletionProvider: MultipleCompletionProvider {
    private let visibleTexts: [String]
    private var storedSuggestionCounts: [Int] = []

    init(visibleTexts: [String]) {
        self.visibleTexts = visibleTexts
    }

    func recordedSuggestionCounts() -> [Int] {
        storedSuggestionCounts
    }

    func complete(context: TextContext) async throws -> Suggestion {
        storedSuggestionCounts.append(1)
        return suggestion(visibleText: visibleTexts[0], context: context)
    }

    func complete(
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?,
        clipboardContext: ClipboardContextSnapshot?,
        options: CompletionOptions
    ) async throws -> [Suggestion] {
        storedSuggestionCounts.append(options.suggestionCount)
        return visibleTexts.prefix(options.suggestionCount).map {
            suggestion(visibleText: $0, context: context)
        }
    }

    private func suggestion(visibleText: String, context: TextContext) -> Suggestion {
        Suggestion(
            baseContextID: context.id,
            visibleText: visibleText,
            rawText: "raw:\(visibleText)",
            latencyMs: 12
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

private actor LifecycleCompletionProvider: CompletionProvider, RuntimeSwitchPreparingCompletionProvider {
    private let visibleText: String
    private let delayNanoseconds: UInt64
    private var storedCallCount = 0
    private var storedPrepareCount = 0

    init(visibleText: String, delayNanoseconds: UInt64) {
        self.visibleText = visibleText
        self.delayNanoseconds = delayNanoseconds
    }

    func waitForCallCount(_ count: Int) async {
        while storedCallCount < count {
            await Task.yield()
        }
    }

    func waitForPrepareCount(_ count: Int) async {
        while storedPrepareCount < count {
            await Task.yield()
        }
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

    func prepareForRuntimeSwitch() async {
        storedPrepareCount += 1
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

private actor CountingRemoteFailureCompletionProvider: CompletionProvider {
    private let error: RemoteCompletionError
    private var storedCallCount = 0

    init(error: RemoteCompletionError) {
        self.error = error
    }

    func getCallCount() -> Int {
        storedCallCount
    }

    func complete(context: TextContext) async throws -> Suggestion {
        storedCallCount += 1
        throw error
    }
}

private actor StaticVisualContextProvider: StableFieldVisualContextProvider {
    let snapshot: VisualContextSnapshot?
    private var storedStableFieldIdentity: StableFieldIdentity?

    init(snapshot: VisualContextSnapshot?) {
        self.snapshot = snapshot
    }

    func currentVisualContext() async -> VisualContextSnapshot? {
        snapshot
    }

    func currentVisualContext(for stableFieldIdentity: StableFieldIdentity?) async -> VisualContextSnapshot? {
        storedStableFieldIdentity = stableFieldIdentity
        return snapshot
    }

    func recordedStableFieldIdentity() -> StableFieldIdentity? {
        storedStableFieldIdentity
    }
}

private actor SuspendedStableVisualContextProvider: StableFieldVisualContextProvider {
    private var continuations: [CheckedContinuation<VisualContextSnapshot?, Never>] = []
    private var stableFieldIdentities: [StableFieldIdentity?] = []

    func currentVisualContext() async -> VisualContextSnapshot? {
        await currentVisualContext(for: nil)
    }

    func currentVisualContext(for stableFieldIdentity: StableFieldIdentity?) async -> VisualContextSnapshot? {
        stableFieldIdentities.append(stableFieldIdentity)
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func waitForPendingRequestCount(_ count: Int) async {
        while continuations.count < count {
            await Task.yield()
        }
    }

    func resumeNext(with snapshot: VisualContextSnapshot?) {
        guard !continuations.isEmpty else {
            return
        }
        continuations.removeFirst().resume(returning: snapshot)
    }

    func recordedStableFieldIdentities() -> [StableFieldIdentity] {
        stableFieldIdentities.compactMap { $0 }
    }
}

private final class ClearingSuspendedStableVisualContextProvider: StableFieldVisualContextProvider, VisualContextSessionClearing, @unchecked Sendable {
    private let lock = NSLock()
    private var continuations: [CheckedContinuation<VisualContextSnapshot?, Never>] = []
    private var clearCount = 0

    func currentVisualContext() async -> VisualContextSnapshot? {
        await currentVisualContext(for: nil)
    }

    func currentVisualContext(for stableFieldIdentity: StableFieldIdentity?) async -> VisualContextSnapshot? {
        await withCheckedContinuation { continuation in
            lock.lock()
            continuations.append(continuation)
            lock.unlock()
        }
    }

    func clearVisualContextSession() {
        lock.lock()
        clearCount += 1
        let pendingContinuations = continuations
        continuations.removeAll()
        lock.unlock()

        for continuation in pendingContinuations {
            continuation.resume(returning: nil)
        }
    }

    func waitForPendingRequestCount(_ count: Int) async {
        while pendingRequestCount() < count {
            await Task.yield()
        }
    }

    func waitForClearCount(_ count: Int) async {
        while currentClearCount() < count {
            await Task.yield()
        }
    }

    private func pendingRequestCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return continuations.count
    }

    private func currentClearCount() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return clearCount
    }
}

private struct StaticClipboardContextProvider: ClipboardContextProvider {
    let snapshot: ClipboardContextSnapshot?

    func currentClipboardContext(
        for context: TextContext,
        privacySettings: PrivacySettings
    ) -> ClipboardContextSnapshot? {
        snapshot
    }
}

private actor RecordingVisualContextCompletionProvider: VisualContextAwareCompletionProvider {
    private var storedContext: TextContext?
    private var storedVisualContext: VisualContextSnapshot?
    private var storedPrivacySettings: PrivacySettings?

    func recordedContext() -> TextContext? {
        storedContext
    }

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
        storedContext = context
        storedPrivacySettings = privacySettings
        storedVisualContext = visualContext
        return Suggestion(baseContextID: context.id, visibleText: "continue this", latencyMs: 12)
    }
}

private actor RecordingClipboardContextCompletionProvider: ClipboardContextAwareCompletionProvider {
    private var storedContext: TextContext?
    private var storedVisualContext: VisualContextSnapshot?
    private var storedClipboardContext: ClipboardContextSnapshot?
    private var storedPrivacySettings: PrivacySettings?

    func recordedContext() -> TextContext? {
        storedContext
    }

    func recordedVisualContext() -> VisualContextSnapshot? {
        storedVisualContext
    }

    func recordedClipboardContext() -> ClipboardContextSnapshot? {
        storedClipboardContext
    }

    func recordedPrivacySettings() -> PrivacySettings? {
        storedPrivacySettings
    }

    func complete(context: TextContext) async throws -> Suggestion {
        try await complete(
            context: context,
            privacySettings: PrivacySettings(),
            visualContext: nil,
            clipboardContext: nil
        )
    }

    func complete(
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?
    ) async throws -> Suggestion {
        try await complete(
            context: context,
            privacySettings: privacySettings,
            visualContext: visualContext,
            clipboardContext: nil
        )
    }

    func complete(
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?,
        clipboardContext: ClipboardContextSnapshot?
    ) async throws -> Suggestion {
        storedContext = context
        storedVisualContext = visualContext
        storedPrivacySettings = privacySettings
        storedClipboardContext = clipboardContext
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
private final class ReplacingSelectionTextInserter: TextInserter {
    private(set) var documentText: String
    private(set) var insertedText = ""
    private let selectedRange: NSRange
    private var insertionLocation: Int
    private var hasReplacedSelection = false

    init(documentText: String, selectedRange: NSRange) {
        self.documentText = documentText
        self.selectedRange = selectedRange
        self.insertionLocation = selectedRange.location
    }

    func acceptNextWord(from suggestion: inout Suggestion) async throws -> String? {
        guard let token = suggestion.acceptNextWord() else {
            return nil
        }
        insert(token)
        return token
    }

    func acceptAll(from suggestion: inout Suggestion) async throws -> String? {
        guard let token = suggestion.acceptAll() else {
            return nil
        }
        insert(token)
        return token
    }

    private func insert(_ text: String) {
        let replacementRange = NSRange(
            location: insertionLocation,
            length: hasReplacedSelection ? 0 : selectedRange.length
        )
        documentText = (documentText as NSString).replacingCharacters(in: replacementRange, with: text)
        insertionLocation += (text as NSString).length
        insertedText += text
        hasReplacedSelection = true
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

@MainActor
private final class RecordingProductivityMetrics: ProductivityMetricsRecording {
    private(set) var acceptedTexts: [String] = []
    private(set) var dismissedSuggestions = 0
    private(set) var latencies: [Int] = []
    private(set) var completionLatencyReports: [CompletionLatencyReport] = []
    private(set) var insertionLatencies: [Int] = []

    func recordAcceptedText(_ text: String) {
        acceptedTexts.append(text)
    }

    func recordDismissedSuggestion() {
        dismissedSuggestions += 1
    }

    func recordBackendLatency(_ latencyMs: Int) {
        latencies.append(latencyMs)
    }

    func recordCompletionLatency(_ report: CompletionLatencyReport) {
        completionLatencyReports.append(report)
        if let backendMs = report.backendMs {
            latencies.append(backendMs)
        }
    }

    func recordInsertionLatency(_ latencyMs: Int) {
        insertionLatencies.append(latencyMs)
    }
}

private struct TestKeystrokeCharacterTranslator: KeystrokeBufferCharacterTranslating {
    let characters: [UInt16: String]

    func character(forKeyCode keyCode: UInt16) -> String? {
        characters[keyCode]
    }
}
