import AppKit
import Foundation

final class InputSuppressionController {
    private let lock = NSLock()
    private let shortcutGraceInterval: TimeInterval
    private let keyReleaseSuppressionInterval: TimeInterval
    private let syntheticInputSuppressionInterval: TimeInterval
    private let now: () -> Date
    private var suggestionActive = false
    private var shortcutGraceUntil: Date = .distantPast
    private var lastConsumedShortcutKeyCode: UInt16?
    private var lastConsumedShortcutEventTimestamp: CGEventTimestamp?
    private var suppressedKeyReleases: [UInt16: Date] = [:]
    private var syntheticInputSuppressedUntil: Date = .distantPast

    init(
        shortcutGraceInterval: TimeInterval = 0.9,
        keyReleaseSuppressionInterval: TimeInterval = 1.2,
        syntheticInputSuppressionInterval: TimeInterval = 0.35,
        now: @escaping () -> Date = { Date() }
    ) {
        self.shortcutGraceInterval = shortcutGraceInterval
        self.keyReleaseSuppressionInterval = keyReleaseSuppressionInterval
        self.syntheticInputSuppressionInterval = syntheticInputSuppressionInterval
        self.now = now
    }

    var isShortcutArmed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return suggestionActive || now() <= shortcutGraceUntil
    }

    func setSuggestionActive(_ active: Bool) {
        lock.lock()
        suggestionActive = active
        lock.unlock()
    }

    func clearShortcutGrace() {
        lock.lock()
        shortcutGraceUntil = .distantPast
        lock.unlock()
    }

    func reset() {
        lock.lock()
        suggestionActive = false
        shortcutGraceUntil = .distantPast
        lastConsumedShortcutKeyCode = nil
        lastConsumedShortcutEventTimestamp = nil
        suppressedKeyReleases = [:]
        syntheticInputSuppressedUntil = .distantPast
        lock.unlock()
    }

    func consumeShortcutIfNeeded(keyCode: UInt16, eventTimestamp: CGEventTimestamp) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        if eventTimestamp > 0,
           lastConsumedShortcutKeyCode == keyCode,
           lastConsumedShortcutEventTimestamp == eventTimestamp {
            GeometryDebug.log("shortcut-consumed duplicate-suppressed keyCode=\(keyCode)")
            return false
        }

        let currentDate = now()
        lastConsumedShortcutKeyCode = keyCode
        lastConsumedShortcutEventTimestamp = eventTimestamp
        pruneExpiredSuppressedKeyReleases(now: currentDate)
        suppressedKeyReleases[keyCode] = currentDate.addingTimeInterval(keyReleaseSuppressionInterval)
        shortcutGraceUntil = currentDate.addingTimeInterval(shortcutGraceInterval)
        return true
    }

    func shouldSuppressKeyRelease(keyCode: UInt16) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let currentDate = now()
        pruneExpiredSuppressedKeyReleases(now: currentDate)
        guard let suppressUntil = suppressedKeyReleases[keyCode],
              currentDate <= suppressUntil else {
            return false
        }
        return true
    }

    func recordSyntheticInput() {
        lock.lock()
        let suppressUntil = now().addingTimeInterval(syntheticInputSuppressionInterval)
        if suppressUntil > syntheticInputSuppressedUntil {
            syntheticInputSuppressedUntil = suppressUntil
        }
        lock.unlock()
    }

    func shouldSuppressSyntheticInput(_ inputEvent: CapturedInputEvent) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        guard case .text = inputEvent,
              now() <= syntheticInputSuppressedUntil else {
            return false
        }
        return true
    }

    private func pruneExpiredSuppressedKeyReleases(now: Date) {
        suppressedKeyReleases = suppressedKeyReleases.filter { $0.value >= now }
    }
}
