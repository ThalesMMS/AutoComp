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
    private var syntheticInputBudget = SyntheticInputBudget()

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

    func clearConsumedShortcut(keyCode: UInt16) {
        lock.lock()
        shortcutGraceUntil = .distantPast
        lastConsumedShortcutKeyCode = nil
        lastConsumedShortcutEventTimestamp = nil
        suppressedKeyReleases[keyCode] = nil
        lock.unlock()
    }

    func reset() {
        lock.lock()
        suggestionActive = false
        shortcutGraceUntil = .distantPast
        lastConsumedShortcutKeyCode = nil
        lastConsumedShortcutEventTimestamp = nil
        suppressedKeyReleases = [:]
        syntheticInputBudget = SyntheticInputBudget()
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

    func consumeSuppressedKeyRelease(keyCode: UInt16) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let currentDate = now()
        pruneExpiredSuppressedKeyReleases(now: currentDate)
        guard let suppressUntil = suppressedKeyReleases[keyCode],
              currentDate <= suppressUntil else {
            return false
        }
        suppressedKeyReleases[keyCode] = nil
        return true
    }

    func registerSyntheticInsertion(expectedKeyDownCount: Int, expectedKeyUpCount: Int) {
        let keyDownCount = max(0, expectedKeyDownCount)
        let keyUpCount = max(0, expectedKeyUpCount)
        guard keyDownCount > 0 || keyUpCount > 0 else {
            return
        }

        lock.lock()
        let suppressUntil = now().addingTimeInterval(syntheticInputSuppressionInterval)
        syntheticInputBudget.expectedKeyDownCount += keyDownCount
        syntheticInputBudget.expectedKeyUpCount += keyUpCount
        syntheticInputBudget.expiresAt = max(syntheticInputBudget.expiresAt, suppressUntil)
        let remainingKeyDown = syntheticInputBudget.expectedKeyDownCount
        let remainingKeyUp = syntheticInputBudget.expectedKeyUpCount
        lock.unlock()

        GeometryDebug.log("synthetic-input registered keyDown=\(keyDownCount) keyUp=\(keyUpCount) remainingKeyDown=\(remainingKeyDown) remainingKeyUp=\(remainingKeyUp)")
    }

    func consumeIfSynthetic(event: CGEvent) -> Bool {
        consumeIfSynthetic(type: event.type, event: event)
    }

    func consumeIfSynthetic(type: CGEventType, event: CGEvent) -> Bool {
        guard type == .keyDown || type == .keyUp else {
            return false
        }

        lock.lock()
        let currentDate = now()
        guard currentDate <= syntheticInputBudget.expiresAt else {
            syntheticInputBudget = SyntheticInputBudget()
            lock.unlock()
            return false
        }

        var consumed = false
        switch type {
        case .keyDown where syntheticInputBudget.expectedKeyDownCount > 0:
            syntheticInputBudget.expectedKeyDownCount -= 1
            consumed = true
        case .keyUp where syntheticInputBudget.expectedKeyUpCount > 0:
            syntheticInputBudget.expectedKeyUpCount -= 1
            consumed = true
        default:
            break
        }

        let remainingKeyDown = syntheticInputBudget.expectedKeyDownCount
        let remainingKeyUp = syntheticInputBudget.expectedKeyUpCount
        if remainingKeyDown == 0 && remainingKeyUp == 0 {
            syntheticInputBudget = SyntheticInputBudget()
        }
        lock.unlock()

        guard consumed else {
            return false
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        GeometryDebug.log("suppressed-synthetic-input type=\(type.debugName) keyCode=\(keyCode) remainingKeyDown=\(remainingKeyDown) remainingKeyUp=\(remainingKeyUp)")
        return true
    }

    private func pruneExpiredSuppressedKeyReleases(now: Date) {
        suppressedKeyReleases = suppressedKeyReleases.filter { $0.value >= now }
    }
}

private struct SyntheticInputBudget {
    var expectedKeyDownCount = 0
    var expectedKeyUpCount = 0
    var expiresAt: Date = .distantPast
}

private extension CGEventType {
    var debugName: String {
        switch self {
        case .keyDown:
            "keyDown"
        case .keyUp:
            "keyUp"
        default:
            "\(rawValue)"
        }
    }
}
