import AppKit
import AutoCompCore
@testable import AutoCompApp
import XCTest

final class TestFixturesCoverageTests: XCTestCase {
    func testTextContextFixturesDocumentRealAppCases() {
        let cases = TextContextFixtures.documentedRealAppCases

        XCTAssertEqual(cases["Chrome"]?.app.bundleID, "com.google.Chrome")
        XCTAssertEqual(cases["Google Docs"]?.domain, "docs.google.com")
        XCTAssertEqual(cases["Notes"]?.app.bundleID, "com.apple.Notes")
        XCTAssertEqual(cases["Slack"]?.app.bundleID, "com.tinyspeck.slackmacgap")
        XCTAssertEqual(cases["Firefox"]?.app.bundleID, "org.mozilla.firefox")
        XCTAssertTrue(cases.values.allSatisfy { $0.stableFieldIdentity != nil })
    }

    func testFIMFixtureBuildsRequestWithoutAX() {
        let context = TextContextFixtures.textEdit(
            prefix: "A reuniao ",
            suffix: " porque o prazo mudou."
        )

        let request = CompletionRequestFactory().makeRequest(
            for: context,
            configuration: RemoteCompletionConfiguration(
                baseURL: "http://127.0.0.1:8000",
                apiKey: "local",
                model: "fixture-model"
            )
        )

        XCTAssertEqual(request.mode, .fillInMiddle)
        XCTAssertEqual(request.truncatedTextAfterCursor, " porque o prazo mudou.")
        XCTAssertTrue(request.fimSuffixInjected)
    }

    @MainActor
    func testOverlayGeometryFixtureResolvesWithoutWindow() {
        let fixture = OverlayGeometryFixtures.directCaretContext()
        let validation = OverlayGeometryFixtures.validator.validate(context: fixture.context)

        XCTAssertNotNil(validation.caretRect)
        XCTAssertNotNil(validation.focusedElementRect)

        let layout = InlineGhostTextLayout.resolve(
            text: fixture.suggestion.visibleText,
            font: .systemFont(ofSize: 14),
            textDirection: .leftToRight,
            anchorFrame: fixture.context.caretRect ?? OverlayGeometryFixtures.caretRect,
            inputFrame: fixture.context.focusedElementRect,
            visibleFrame: OverlayGeometryFixtures.visibleFrame,
            observedCharacterWidth: fixture.context.observedCharacterWidth,
            geometryQuality: fixture.context.caretGeometryQuality
        )

        XCTAssertGreaterThan(layout.panelFrame.width, 0)
        XCTAssertGreaterThan(layout.panelFrame.height, 0)
    }

    @MainActor
    func testFakeTextInserterAcceptsWithoutPostingCGEvents() async throws {
        let context = TextContextFixtures.textEdit(prefix: "Please ")
        var suggestion = Suggestion(
            baseContextID: context.id,
            visibleText: "finish today",
            latencyMs: 1
        )
        let inserter = FakeTextInserter()

        let acceptedWord = try await inserter.acceptNextWord(from: &suggestion)
        let acceptedRemainder = try await inserter.acceptAll(from: &suggestion)

        XCTAssertEqual(acceptedWord, "finish ")
        XCTAssertEqual(acceptedRemainder, "today")
        XCTAssertEqual(inserter.nextWordCalls, 1)
        XCTAssertEqual(inserter.acceptAllCalls, 1)
        XCTAssertEqual(inserter.insertedTexts, ["finish ", "today"])
    }

    func testInputEventFixturesCoverTriggerAcceptanceMutationAndNavigation() {
        XCTAssertTrue(InputEventFixtures.spaceTrigger.isSuggestionTrigger)
        XCTAssertTrue(InputEventFixtures.spaceTrigger.shouldSchedulePrediction)
        XCTAssertEqual(InputEventFixtures.tab.eventKind, .acceptance)
        XCTAssertEqual(InputEventFixtures.acceptAll.eventKind, .fullAcceptance)
        XCTAssertTrue(InputEventFixtures.delete.shouldClearSuggestion)
        XCTAssertFalse(InputEventFixtures.arrowLeft.shouldSchedulePrediction)
        XCTAssertEqual(InputEventFixtures.pointer.eventKind, .navigation)
    }

    func testFakeProvidersRecordContextVisualClipboardAndOptions() async throws {
        let context = TextContextFixtures.googleDocs(prefix: "The plan ")
        let visualSnapshot = VisualContextSnapshot(
            summary: "Visible heading: Launch Plan",
            stableFieldIdentity: context.stableFieldIdentity
        )
        let clipboardSnapshot = ClipboardContextSnapshot(summary: "Launch notes", status: .included)
        let provider = FakeCompletionProvider(suggestions: [
            Suggestion(baseContextID: context.id, visibleText: "ships Friday", latencyMs: 3),
            Suggestion(baseContextID: context.id, visibleText: "moves Monday", latencyMs: 4)
        ])

        let suggestions = try await provider.complete(
            context: context,
            privacySettings: PrivacySettings(clipboardContextEnabled: true, screenContextEnabled: true),
            visualContext: visualSnapshot,
            clipboardContext: clipboardSnapshot,
            options: CompletionOptions(suggestionCount: 2)
        )
        let recordedContexts = await provider.recordedContexts()
        let recordedVisualContexts = await provider.recordedVisualContexts()
        let recordedClipboardContexts = await provider.recordedClipboardContexts()
        let recordedOptions = await provider.recordedOptions()

        XCTAssertEqual(suggestions.map { $0.visibleText }, ["ships Friday", "moves Monday"])
        XCTAssertEqual(recordedContexts, [context])
        XCTAssertEqual(recordedVisualContexts, [visualSnapshot])
        XCTAssertEqual(recordedClipboardContexts, [clipboardSnapshot])
        XCTAssertEqual(recordedOptions, [CompletionOptions(suggestionCount: 2)])
    }

    func testFakeContextAndVisualProvidersAvoidRealCapture() async throws {
        let first = TextContextFixtures.chrome(prefix: "First ")
        let second = TextContextFixtures.chrome(prefix: "Second ")
        let contextProvider = FakeContextProvider(contexts: [first, second])
        let visualProvider = FakeVisualContextProvider(
            snapshot: VisualContextSnapshot(
                summary: "Visible card",
                stableFieldIdentity: first.stableFieldIdentity
            )
        )

        let firstResolved = try await contextProvider.currentContext()
        let secondResolved = try await contextProvider.currentContext()
        _ = await visualProvider.currentVisualContext(for: first.stableFieldIdentity)
        visualProvider.clearVisualContextSession()

        XCTAssertEqual(firstResolved, first)
        XCTAssertEqual(secondResolved, second)
        XCTAssertEqual(visualProvider.requestedIdentities(), [first.stableFieldIdentity])
        XCTAssertEqual(visualProvider.clearCount(), 1)
    }

    @MainActor
    func testSessionReconciliationFixturesCoverPublicationAcceptanceAndTypedThrough() async throws {
        let context = TextContextFixtures.notes(prefix: "Please ")
        let suggestion = Suggestion(
            baseContextID: context.id,
            visibleText: "finish today",
            latencyMs: 1
        )
        let presenter = FakeSuggestionPresenter()
        let publicationController = SuggestionPublicationController(presenter: presenter)
        let sessionController = AcceptanceSessionController()
        let acceptanceController = SuggestionAcceptanceController(sessionController: sessionController)
        let inserter = FakeTextInserter()

        let publication = publicationController.publish(
            suggestion,
            context: context,
            displayMode: .inline,
            collectionAllowed: false
        )
        let publishedSuggestion = try XCTUnwrap(publication.publishedSuggestion)
        sessionController.recordPublication(context: context, suggestion: publishedSuggestion)

        let accepted = try await acceptanceController.acceptNextWord(
            currentSuggestion: publishedSuggestion,
            currentContext: context,
            using: inserter
        )
        let remainingSuggestion = try XCTUnwrap(accepted?.currentSuggestion)
        let acceptedContext = context.replacingTextBeforeCursor("Please finish ")
        let typedThroughContext = context.replacingTextBeforeCursor("Please finish t")

        let acceptanceEcho = sessionController.handleAcceptedSuggestionSession(
            context: acceptedContext,
            currentSuggestion: remainingSuggestion
        )
        let typedThrough = sessionController.handleAcceptedSuggestionSession(
            context: typedThroughContext,
            currentSuggestion: remainingSuggestion
        )

        XCTAssertEqual(presenter.shown.count, 1)
        XCTAssertEqual(accepted?.acceptedText, "finish ")
        XCTAssertEqual(inserter.insertedTexts, ["finish "])
        if case .handled(let result) = acceptanceEcho {
            XCTAssertEqual(result.statusMessage, "Continuing accepted suggestion")
            XCTAssertFalse(result.shouldSchedulePrediction)
        } else {
            XCTFail("Expected accepted echo to be handled")
        }
        if case .handled(let result) = typedThrough {
            XCTAssertEqual(result.currentSuggestion?.remainingText, "oday")
            XCTAssertEqual(result.statusMessage, "Continuing accepted suggestion")
        } else {
            XCTFail("Expected typed-through text to be handled")
        }
    }
}
