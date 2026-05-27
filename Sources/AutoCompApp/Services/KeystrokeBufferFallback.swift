import AppKit
import AutoCompCore
import Carbon
import Foundation

protocol KeystrokeBufferCharacterTranslating {
    func character(forKeyCode keyCode: UInt16) -> String?
}

struct CurrentKeyboardLayoutCharacterTranslator: KeystrokeBufferCharacterTranslating {
    func character(forKeyCode keyCode: UInt16) -> String? {
        guard let source = TISCopyCurrentKeyboardLayoutInputSource()?.takeRetainedValue(),
              let rawLayoutData = TISGetInputSourceProperty(
                source,
                kTISPropertyUnicodeKeyLayoutData
              ) else {
            return nil
        }

        let layoutData = Unmanaged<CFData>
            .fromOpaque(rawLayoutData)
            .takeUnretainedValue()
        guard let layoutBytes = CFDataGetBytePtr(layoutData) else {
            return nil
        }

        return layoutBytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            var deadKeyState: UInt32 = 0
            var output = [UniChar](repeating: 0, count: 8)
            var outputLength = 0
            let status = output.withUnsafeMutableBufferPointer { buffer in
                UCKeyTranslate(
                    layout,
                    keyCode,
                    UInt16(kUCKeyActionDown),
                    0,
                    UInt32(LMGetKbdType()),
                    OptionBits(kUCKeyTranslateNoDeadKeysBit),
                    &deadKeyState,
                    buffer.count,
                    &outputLength,
                    buffer.baseAddress!
                )
            }

            guard status == noErr,
                  outputLength > 0 else {
                return nil
            }

            return output.withUnsafeBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else {
                    return nil
                }
                return String(utf16CodeUnits: baseAddress, count: outputLength)
            }
        }
    }
}

@MainActor
final class KeystrokeBufferFallback {
    struct Configuration: Equatable {
        let ttl: TimeInterval
        let maxCharacters: Int

        init(ttl: TimeInterval = 8, maxCharacters: Int = 512) {
            self.ttl = ttl
            self.maxCharacters = max(1, maxCharacters)
        }
    }

    private struct TargetIdentity: Equatable {
        let app: AppIdentity
        let domain: String?
        let focusedElementID: String?
        let stableFieldIdentity: StableFieldIdentity?

        init(app: AppIdentity) {
            self.app = app
            self.domain = nil
            self.focusedElementID = nil
            self.stableFieldIdentity = nil
        }

        init(context: TextContext) {
            self.app = context.app
            self.domain = context.domain
            self.focusedElementID = context.focusedElementID
            self.stableFieldIdentity = context.stableFieldIdentity
        }

        func matches(_ context: TextContext) -> Bool {
            guard app == context.app,
                  domain == context.domain else {
                return false
            }

            if focusedElementID == context.focusedElementID {
                return true
            }

            guard let stableFieldIdentity,
                  let contextStableFieldIdentity = context.stableFieldIdentity else {
                return false
            }

            return stableFieldIdentity.matchesStableTarget(contextStableFieldIdentity)
        }
    }

    private static let resetTextKeyCodes: Set<UInt16> = [51, 117]

    private let configuration: Configuration
    private let now: () -> Date
    private let frontmostAppProvider: @MainActor () -> AppIdentity?
    private let characterTranslator: KeystrokeBufferCharacterTranslating
    private var text = ""
    private var target: TargetIdentity?
    private var lastUpdatedAt: Date?

    init(
        configuration: Configuration = Configuration(),
        now: @escaping () -> Date = Date.init,
        frontmostAppProvider: @MainActor @escaping () -> AppIdentity? = KeystrokeBufferFallback.defaultFrontmostApp,
        characterTranslator: KeystrokeBufferCharacterTranslating = CurrentKeyboardLayoutCharacterTranslator()
    ) {
        self.configuration = configuration
        self.now = now
        self.frontmostAppProvider = frontmostAppProvider
        self.characterTranslator = characterTranslator
    }

    var bufferedText: String {
        discardExpiredIfNeeded()
        return text
    }

    func observeTrustedContext(_ context: TextContext) {
        let trustedTarget = TargetIdentity(context: context)
        guard let target else {
            self.target = trustedTarget
            return
        }

        if !target.matches(context) {
            reset()
            self.target = trustedTarget
        } else {
            self.target = trustedTarget
        }
    }

    func observeFocusFailure(_ error: Error) {
        guard shouldDiscardForFocusFailure(error) else {
            return
        }
        reset()
    }

    func record(
        event: CapturedInputEvent,
        currentContext: TextContext?,
        inputMethodState: InputMethodState
    ) {
        discardExpiredIfNeeded()
        guard inputMethodState.allowsAutomaticSuggestions else {
            reset()
            return
        }

        if let currentContext,
           !currentContext.captureSources.contains(.keystrokeBufferLowTrust) {
            observeTrustedContext(currentContext)
        } else if !validateFrontmostAppTarget() {
            return
        }

        switch event {
        case .text(let keyCode, _):
            guard !Self.resetTextKeyCodes.contains(keyCode),
                  let character = characterTranslator.character(forKeyCode: keyCode),
                  !character.isEmpty else {
                reset()
                return
            }
            append(character)
        case .navigation, .dismissal, .tab, .acceptAll, .shortcutMutation, .pointer:
            reset()
        }
    }

    func fallbackContext(after error: Error) -> TextContext? {
        guard fallbackAllowed(after: error) else {
            reset()
            return nil
        }

        discardExpiredIfNeeded()
        guard !text.isEmpty else {
            return nil
        }

        guard let target = target ?? frontmostAppProvider().map(TargetIdentity.init(app:)) else {
            reset()
            return nil
        }
        self.target = target

        let length = (text as NSString).length
        return TextContext(
            app: target.app,
            domain: target.domain,
            focusedElementID: target.focusedElementID ?? "keystroke-buffer-low-trust",
            stableFieldIdentity: target.stableFieldIdentity,
            textBeforeCursor: text,
            textAfterCursor: nil,
            selectedText: nil,
            fullTextWindow: text,
            selectedRange: NSRange(location: length, length: 0),
            caretGeometryQuality: .unavailable,
            captureSources: [.keystrokeBufferLowTrust],
            createdAt: now()
        )
    }

    func reset() {
        text = ""
        target = nil
        lastUpdatedAt = nil
    }

    private func append(_ character: String) {
        text.append(character)
        if text.count > configuration.maxCharacters {
            text = String(text.suffix(configuration.maxCharacters))
        }
        lastUpdatedAt = now()
    }

    private func validateFrontmostAppTarget() -> Bool {
        guard let frontmostApp = frontmostAppProvider() else {
            reset()
            return false
        }

        if let target {
            guard target.app == frontmostApp else {
                reset()
                self.target = TargetIdentity(app: frontmostApp)
                return true
            }
            return true
        }

        target = TargetIdentity(app: frontmostApp)
        return true
    }

    private func discardExpiredIfNeeded() {
        guard let lastUpdatedAt else {
            return
        }

        if now().timeIntervalSince(lastUpdatedAt) > configuration.ttl {
            reset()
        }
    }

    private func fallbackAllowed(after error: Error) -> Bool {
        guard let contextError = error as? AXTextContextError else {
            return false
        }

        switch contextError {
        case .noReadableText, .noFocusedElement:
            return true
        case .accessibilityNotTrusted, .noFrontmostApplication, .secureOrUnsupportedField:
            return false
        }
    }

    private func shouldDiscardForFocusFailure(_ error: Error) -> Bool {
        guard let contextError = error as? AXTextContextError else {
            return false
        }

        switch contextError {
        case .accessibilityNotTrusted, .noFrontmostApplication, .secureOrUnsupportedField:
            return true
        case .noFocusedElement, .noReadableText:
            return false
        }
    }

    private static func defaultFrontmostApp() -> AppIdentity? {
        guard let runningApplication = NSWorkspace.shared.frontmostApplication else {
            return nil
        }

        let bundleID = runningApplication.bundleIdentifier
            ?? "process-\(runningApplication.processIdentifier)"
        return AppIdentity(
            bundleID: bundleID,
            displayName: runningApplication.localizedName ?? bundleID,
            processID: runningApplication.processIdentifier
        )
    }
}
