import AutoCompCore
@testable import AutoCompApp
import XCTest

@MainActor
final class KeystrokeBufferFallbackTests: XCTestCase {
    func testFallbackContextUsesLowTrustSourceAndBoundsBufferedText() {
        let app = Self.app(bundleID: "com.apple.TextEdit")
        let fallback = KeystrokeBufferFallback(
            configuration: .init(ttl: 8, maxCharacters: 3),
            frontmostAppProvider: { app },
            characterTranslator: TestCharacterTranslator.qwerty
        )

        fallback.record(event: .text(keyCode: 35, isSuggestionTrigger: false), currentContext: nil, inputMethodState: .asciiCompatible)
        fallback.record(event: .text(keyCode: 37, isSuggestionTrigger: false), currentContext: nil, inputMethodState: .asciiCompatible)
        fallback.record(event: .text(keyCode: 14, isSuggestionTrigger: false), currentContext: nil, inputMethodState: .asciiCompatible)
        fallback.record(event: .text(keyCode: 0, isSuggestionTrigger: false), currentContext: nil, inputMethodState: .asciiCompatible)

        let context = fallback.fallbackContext(after: AXTextContextError.noReadableText)

        XCTAssertEqual(context?.app, app)
        XCTAssertEqual(context?.textBeforeCursor, "lea")
        XCTAssertEqual(context?.fullTextWindow, "lea")
        XCTAssertEqual(context?.captureSources, [.keystrokeBufferLowTrust])
        XCTAssertEqual(context?.caretGeometryQuality, .unavailable)
        XCTAssertEqual(context?.selectedRange, NSRange(location: 3, length: 0))
    }

    func testExpiredBufferIsDiscarded() {
        let clock = KeystrokeBufferTestClock()
        let fallback = KeystrokeBufferFallback(
            configuration: .init(ttl: 2, maxCharacters: 32),
            now: { clock.now },
            frontmostAppProvider: { Self.app() },
            characterTranslator: TestCharacterTranslator.qwerty
        )

        fallback.record(event: .text(keyCode: 35, isSuggestionTrigger: false), currentContext: nil, inputMethodState: .asciiCompatible)
        clock.advance(by: 3)

        XCTAssertNil(fallback.fallbackContext(after: AXTextContextError.noReadableText))
        XCTAssertEqual(fallback.bufferedText, "")
    }

    func testSecureFieldErrorBlocksAndClearsFallback() {
        let fallback = KeystrokeBufferFallback(
            frontmostAppProvider: { Self.app() },
            characterTranslator: TestCharacterTranslator.qwerty
        )

        fallback.record(event: .text(keyCode: 35, isSuggestionTrigger: false), currentContext: nil, inputMethodState: .asciiCompatible)

        XCTAssertNil(fallback.fallbackContext(after: AXTextContextError.secureOrUnsupportedField))
        XCTAssertEqual(fallback.bufferedText, "")
        XCTAssertNil(fallback.fallbackContext(after: AXTextContextError.noReadableText))
    }

    func testTrustedFieldChangeDiscardsBufferedText() {
        let app = Self.app()
        let firstContext = TextContext(
            app: app,
            focusedElementID: "field-a",
            textBeforeCursor: "a"
        )
        let secondContext = TextContext(
            app: app,
            focusedElementID: "field-b",
            textBeforeCursor: "b"
        )
        let fallback = KeystrokeBufferFallback(
            frontmostAppProvider: { app },
            characterTranslator: TestCharacterTranslator.qwerty
        )

        fallback.record(event: .text(keyCode: 35, isSuggestionTrigger: false), currentContext: firstContext, inputMethodState: .asciiCompatible)
        fallback.observeTrustedContext(secondContext)

        XCTAssertEqual(fallback.bufferedText, "")
        XCTAssertNil(fallback.fallbackContext(after: AXTextContextError.noReadableText))
    }

    func testFrontmostAppChangeStartsFreshBufferForNewApp() {
        let firstApp = Self.app(bundleID: "com.example.first", processID: 1)
        let secondApp = Self.app(bundleID: "com.example.second", processID: 2)
        let frontmostApp = FrontmostAppBox(app: firstApp)
        let fallback = KeystrokeBufferFallback(
            frontmostAppProvider: { frontmostApp.app },
            characterTranslator: TestCharacterTranslator.qwerty
        )

        fallback.record(event: .text(keyCode: 0, isSuggestionTrigger: false), currentContext: nil, inputMethodState: .asciiCompatible)
        frontmostApp.app = secondApp
        fallback.record(event: .text(keyCode: 11, isSuggestionTrigger: false), currentContext: nil, inputMethodState: .asciiCompatible)

        let context = fallback.fallbackContext(after: AXTextContextError.noReadableText)
        XCTAssertEqual(context?.app, secondApp)
        XCTAssertEqual(context?.textBeforeCursor, "b")
    }

    func testResetEventsAndInputMethodStateClearBuffer() {
        let fallback = KeystrokeBufferFallback(
            frontmostAppProvider: { Self.app() },
            characterTranslator: TestCharacterTranslator.qwerty
        )

        fallback.record(event: .text(keyCode: 35, isSuggestionTrigger: false), currentContext: nil, inputMethodState: .asciiCompatible)
        fallback.record(event: .navigation(keyCode: 123), currentContext: nil, inputMethodState: .asciiCompatible)
        XCTAssertEqual(fallback.bufferedText, "")

        fallback.record(event: .text(keyCode: 35, isSuggestionTrigger: false), currentContext: nil, inputMethodState: .asciiCompatible)
        fallback.record(event: .shortcutMutation(keyCode: 9), currentContext: nil, inputMethodState: .asciiCompatible)
        XCTAssertEqual(fallback.bufferedText, "")

        fallback.record(event: .text(keyCode: 35, isSuggestionTrigger: false), currentContext: nil, inputMethodState: .asciiCompatible)
        fallback.record(event: .pointer, currentContext: nil, inputMethodState: .asciiCompatible)
        XCTAssertEqual(fallback.bufferedText, "")

        fallback.record(event: .text(keyCode: 35, isSuggestionTrigger: false), currentContext: nil, inputMethodState: .asciiCompatible)
        fallback.record(
            event: .text(keyCode: 37, isSuggestionTrigger: false),
            currentContext: nil,
            inputMethodState: InputMethodState(isASCIICompatible: false)
        )
        XCTAssertEqual(fallback.bufferedText, "")
    }

    func testBufferUsesInjectedKeyboardLayoutTranslatorInsteadOfHardwarePositionMap() {
        let fallback = KeystrokeBufferFallback(
            frontmostAppProvider: { Self.app() },
            characterTranslator: TestCharacterTranslator(characters: [
                0: "q",
                12: "a"
            ])
        )

        fallback.record(event: .text(keyCode: 0, isSuggestionTrigger: false), currentContext: nil, inputMethodState: .asciiCompatible)
        fallback.record(event: .text(keyCode: 12, isSuggestionTrigger: false), currentContext: nil, inputMethodState: .asciiCompatible)

        XCTAssertEqual(fallback.bufferedText, "qa")
    }

    private static func app(
        bundleID: String = "com.apple.TextEdit",
        processID: Int32 = 1
    ) -> AppIdentity {
        AppIdentity(bundleID: bundleID, displayName: "TextEdit", processID: processID)
    }
}

private struct TestCharacterTranslator: KeystrokeBufferCharacterTranslating {
    static let qwerty = TestCharacterTranslator(characters: [
        0: "a",
        11: "b",
        14: "e",
        35: "p",
        37: "l"
    ])

    let characters: [UInt16: String]

    func character(forKeyCode keyCode: UInt16) -> String? {
        characters[keyCode]
    }
}

private final class KeystrokeBufferTestClock {
    private(set) var now = Date(timeIntervalSince1970: 1_000)

    func advance(by interval: TimeInterval) {
        now = now.addingTimeInterval(interval)
    }
}

@MainActor
private final class FrontmostAppBox {
    var app: AppIdentity

    init(app: AppIdentity) {
        self.app = app
    }
}
