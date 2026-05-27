import AppKit
import AutoCompCore
@testable import AutoCompApp
import CoreGraphics
import Foundation

enum TextContextFixtures {
    static let textEditApp = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 101)
    static let notesApp = AppIdentity(bundleID: "com.apple.Notes", displayName: "Notes", processID: 102)
    static let mailApp = AppIdentity(bundleID: "com.apple.mail", displayName: "Mail", processID: 103)
    static let chromeApp = AppIdentity(bundleID: "com.google.Chrome", displayName: "Google Chrome", processID: 104)
    static let slackApp = AppIdentity(bundleID: "com.tinyspeck.slackmacgap", displayName: "Slack", processID: 105)
    static let firefoxApp = AppIdentity(bundleID: "org.mozilla.firefox", displayName: "Firefox", processID: 106)

    static var documentedRealAppCases: [String: TextContext] {
        [
            "Chrome": chrome(prefix: "Draft the update "),
            "Google Docs": googleDocs(prefix: "The launch plan ", suffix: " by Friday."),
            "Notes": notes(prefix: "Remember to "),
            "Slack": slack(prefix: "Can you "),
            "Firefox": firefox(prefix: "Search for ")
        ]
    }

    static func textEdit(
        prefix: String = "Please ",
        suffix: String? = nil,
        selectedText: String? = nil,
        caretRect: CGRect? = OverlayGeometryFixtures.caretRect,
        focusedElementRect: CGRect? = OverlayGeometryFixtures.textFieldRect,
        caretGeometryQuality: CaretGeometryQuality = .directCaret
    ) -> TextContext {
        context(
            app: textEditApp,
            focusedElementID: "textedit-editor",
            prefix: prefix,
            suffix: suffix,
            selectedText: selectedText,
            caretRect: caretRect,
            focusedElementRect: focusedElementRect,
            caretGeometryQuality: caretGeometryQuality
        )
    }

    static func notes(prefix: String, suffix: String? = nil) -> TextContext {
        context(
            app: notesApp,
            focusedElementID: "notes-body",
            prefix: prefix,
            suffix: suffix,
            caretRect: OverlayGeometryFixtures.caretRect,
            focusedElementRect: OverlayGeometryFixtures.textFieldRect,
            caretGeometryQuality: .directCaret
        )
    }

    static func chrome(prefix: String, suffix: String? = nil, domain: String? = "example.com") -> TextContext {
        context(
            app: chromeApp,
            domain: domain,
            focusedElementID: "chrome-textarea",
            prefix: prefix,
            suffix: suffix,
            caretRect: CGRect(x: 520, y: 381, width: 1, height: 16),
            focusedElementRect: CGRect(x: 420, y: 360, width: 640, height: 80),
            caretGeometryQuality: .directCaret
        )
    }

    static func googleDocs(prefix: String, suffix: String? = nil) -> TextContext {
        context(
            app: chromeApp,
            domain: "docs.google.com",
            focusedElementID: "docs-braille-line",
            prefix: prefix,
            suffix: suffix,
            caretRect: CGRect(x: 450, y: 381, width: 0, height: 17),
            focusedElementRect: CGRect(x: 450, y: 381, width: 626, height: 1),
            lineReferenceRect: CGRect(x: 450, y: 381, width: 626, height: 1),
            caretGeometryQuality: .lineMetric
        )
    }

    static func slack(prefix: String, suffix: String? = nil) -> TextContext {
        context(
            app: slackApp,
            focusedElementID: "slack-composer",
            prefix: prefix,
            suffix: suffix,
            caretRect: nil,
            focusedElementRect: CGRect(x: 100, y: 620, width: 760, height: 44),
            caretGeometryQuality: .elementFrame
        )
    }

    static func firefox(prefix: String, suffix: String? = nil, domain: String? = "example.com") -> TextContext {
        context(
            app: firefoxApp,
            domain: domain,
            focusedElementID: "firefox-textarea",
            prefix: prefix,
            suffix: suffix,
            caretRect: nil,
            focusedElementRect: CGRect(x: 120, y: 300, width: 620, height: 48),
            caretGeometryQuality: .elementFrame
        )
    }

    private static func context(
        app: AppIdentity,
        domain: String? = nil,
        focusedElementID: String,
        prefix: String,
        suffix: String?,
        selectedText: String? = nil,
        caretRect: CGRect?,
        focusedElementRect: CGRect?,
        lineReferenceRect: CGRect? = nil,
        caretGeometryQuality: CaretGeometryQuality
    ) -> TextContext {
        TextContext(
            app: app,
            domain: domain,
            focusedElementID: focusedElementID,
            stableFieldIdentity: StableFieldIdentity(
                app: app,
                domain: domain,
                role: "AXTextArea",
                focusedElementFrame: focusedElementRect
            ),
            textBeforeCursor: prefix,
            textAfterCursor: suffix,
            selectedText: selectedText,
            fullTextWindow: prefix + (selectedText ?? "") + (suffix ?? ""),
            selectedRange: selectedText.map { NSRange(location: (prefix as NSString).length, length: ($0 as NSString).length) },
            caretRect: caretRect,
            focusedElementRect: focusedElementRect,
            lineReferenceRect: lineReferenceRect,
            caretGeometryQuality: caretGeometryQuality,
            observedCharacterWidth: 7,
            captureSources: [.accessibility]
        )
    }
}

enum OverlayGeometryFixtures {
    static let screenFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
    static let visibleFrame = CGRect(x: 0, y: 24, width: 1440, height: 852)
    static let textFieldRect = CGRect(x: 100, y: 100, width: 520, height: 40)
    static let caretRect = CGRect(x: 180, y: 110, width: 1, height: 18)

    static var validator: OverlayGeometryValidator {
        OverlayGeometryValidator(screenFrame: screenFrame, visibleFrame: visibleFrame)
    }

    static func directCaretContext(
        text: String = "Please finish ",
        suggestion: String = "the report today"
    ) -> (context: TextContext, suggestion: Suggestion) {
        let context = TextContextFixtures.textEdit(prefix: text)
        let suggestion = Suggestion(
            baseContextID: context.id,
            visibleText: suggestion,
            latencyMs: 12
        )
        return (context, suggestion)
    }
}

enum InputEventFixtures {
    static let spaceTrigger = CapturedInputEvent.text(
        keyCode: CapturedInputEventAdapter.spaceKeyCode,
        isSuggestionTrigger: true
    )
    static let letter = CapturedInputEvent.text(keyCode: 0, isSuggestionTrigger: false)
    static let delete = CapturedInputEvent.text(keyCode: 51, isSuggestionTrigger: false)
    static let tab = CapturedInputEvent.tab
    static let acceptAll = CapturedInputEvent.acceptAll
    static let arrowLeft = CapturedInputEvent.navigation(keyCode: 123)
    static let pointer = CapturedInputEvent.pointer
}

actor FakeCompletionProvider: ClipboardContextAwareCompletionProvider, MultipleCompletionProvider {
    private var suggestions: [Suggestion]
    private let error: Error?
    private var storedContexts: [TextContext] = []
    private var storedPrivacySettings: [PrivacySettings] = []
    private var storedVisualContexts: [VisualContextSnapshot?] = []
    private var storedClipboardContexts: [ClipboardContextSnapshot?] = []
    private var storedOptions: [CompletionOptions] = []

    init(suggestions: [Suggestion], error: Error? = nil) {
        self.suggestions = suggestions
        self.error = error
    }

    init(text: String, error: Error? = nil) {
        self.init(
            suggestions: [
                Suggestion(
                    baseContextID: UUID(),
                    visibleText: text,
                    latencyMs: 1
                )
            ],
            error: error
        )
    }

    func complete(context: TextContext) async throws -> Suggestion {
        try await complete(context: context, privacySettings: PrivacySettings(), visualContext: nil, clipboardContext: nil)
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
        record(
            context: context,
            privacySettings: privacySettings,
            visualContext: visualContext,
            clipboardContext: clipboardContext,
            options: nil
        )
        if let error {
            throw error
        }
        return suggestions.first ?? Suggestion(baseContextID: context.id, visibleText: "", latencyMs: 0)
    }

    func complete(
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?,
        clipboardContext: ClipboardContextSnapshot?,
        options: CompletionOptions
    ) async throws -> [Suggestion] {
        record(
            context: context,
            privacySettings: privacySettings,
            visualContext: visualContext,
            clipboardContext: clipboardContext,
            options: options
        )
        if let error {
            throw error
        }
        return Array(suggestions.prefix(options.suggestionCount))
    }

    func recordedContexts() -> [TextContext] {
        storedContexts
    }

    func recordedVisualContexts() -> [VisualContextSnapshot?] {
        storedVisualContexts
    }

    func recordedClipboardContexts() -> [ClipboardContextSnapshot?] {
        storedClipboardContexts
    }

    func recordedOptions() -> [CompletionOptions] {
        storedOptions
    }

    private func record(
        context: TextContext,
        privacySettings: PrivacySettings,
        visualContext: VisualContextSnapshot?,
        clipboardContext: ClipboardContextSnapshot?,
        options: CompletionOptions?
    ) {
        storedContexts.append(context)
        storedPrivacySettings.append(privacySettings)
        storedVisualContexts.append(visualContext)
        storedClipboardContexts.append(clipboardContext)
        if let options {
            storedOptions.append(options)
        }
    }
}

actor FakeContextProvider: TextContextProvider {
    private var contexts: [TextContext]
    private let error: Error?

    init(contexts: [TextContext], error: Error? = nil) {
        self.contexts = contexts
        self.error = error
    }

    init(context: TextContext) {
        self.init(contexts: [context])
    }

    func currentContext() async throws -> TextContext {
        if let error {
            throw error
        }
        if contexts.count > 1 {
            return contexts.removeFirst()
        }
        guard let context = contexts.first else {
            throw AXTextContextError.noFocusedElement
        }
        return context
    }
}

final class FakeVisualContextProvider: StableFieldVisualContextProvider, VisualContextSessionClearing, @unchecked Sendable {
    private let lock = NSLock()
    private var snapshot: VisualContextSnapshot?
    private var storedRequestedIdentities: [StableFieldIdentity?] = []
    private var storedClearCount = 0

    init(snapshot: VisualContextSnapshot?) {
        self.snapshot = snapshot
    }

    func currentVisualContext() async -> VisualContextSnapshot? {
        lock.withLock {
            snapshot
        }
    }

    func currentVisualContext(for stableFieldIdentity: StableFieldIdentity?) async -> VisualContextSnapshot? {
        lock.withLock {
            storedRequestedIdentities.append(stableFieldIdentity)
            return snapshot
        }
    }

    func clearVisualContextSession() {
        lock.withLock {
            storedClearCount += 1
        }
    }

    func requestedIdentities() -> [StableFieldIdentity?] {
        lock.withLock {
            storedRequestedIdentities
        }
    }

    func clearCount() -> Int {
        lock.withLock {
            storedClearCount
        }
    }
}

@MainActor
final class FakeTextInserter: TextInserter {
    private(set) var nextWordCalls = 0
    private(set) var acceptAllCalls = 0
    private(set) var insertedTexts: [String] = []

    func acceptNextWord(from suggestion: inout Suggestion) async throws -> String? {
        nextWordCalls += 1
        guard let text = suggestion.acceptNextWord() else {
            return nil
        }
        insertedTexts.append(text)
        return text
    }

    func acceptAll(from suggestion: inout Suggestion) async throws -> String? {
        acceptAllCalls += 1
        guard let text = suggestion.acceptAll() else {
            return nil
        }
        insertedTexts.append(text)
        return text
    }
}

@MainActor
final class FakeSuggestionPresenter: SuggestionPresenter {
    private(set) var shown: [(suggestion: Suggestion, context: TextContext, mode: SuggestionDisplayMode)] = []
    private(set) var updated: [(suggestion: Suggestion, context: TextContext, mode: SuggestionDisplayMode)] = []
    private(set) var hideCount = 0

    func show(_ suggestion: Suggestion, for context: TextContext, mode: SuggestionDisplayMode) {
        shown.append((suggestion, context, mode))
    }

    func update(_ suggestion: Suggestion, for context: TextContext, mode: SuggestionDisplayMode) {
        updated.append((suggestion, context, mode))
    }

    func hide() {
        hideCount += 1
    }
}
