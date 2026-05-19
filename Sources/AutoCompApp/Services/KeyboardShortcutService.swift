import AppKit
import Foundation

final class KeyboardShortcutService {
    private var eventTaps: [CFMachPort] = []
    private var runLoopSources: [CFRunLoopSource] = []
    private var onTab: (() -> Void)?
    private var onAcceptAll: (() -> Void)?
    private var onSuggestionTriggerKey: (() -> Void)?
    private let state = ShortcutActivationState()
    private let consumptionLock = NSLock()
    private var lastConsumedShortcutKeyCode: UInt16?
    private var lastConsumedShortcutEventTimestamp: CGEventTimestamp?
    private var suppressedKeyReleases: [UInt16: Date] = [:]
    private let tabKeyCode: UInt16 = 48
    private let spaceKeyCode: UInt16 = 49
    private let rightShiftKeyCode: UInt16 = 60
    private let shortcutGraceInterval: TimeInterval = 0.9
    private let keyReleaseSuppressionInterval: TimeInterval = 1.2

    func start(
        onTab: @escaping () -> Void,
        onAcceptAll: @escaping () -> Void,
        onSuggestionTriggerKey: (() -> Void)? = nil
    ) {
        stop()
        configureHandlers(
            onTab: onTab,
            onAcceptAll: onAcceptAll,
            onSuggestionTriggerKey: onSuggestionTriggerKey
        )

        guard CGPreflightListenEventAccess() else {
            NSLog("AutoComp cannot monitor keyboard shortcuts until Input Monitoring permission is enabled.")
            GeometryDebug.log("shortcut-start rejected reason=input-monitoring-missing")
            return
        }

        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else {
                return Unmanaged.passUnretained(event)
            }

            let service = Unmanaged<KeyboardShortcutService>.fromOpaque(userInfo).takeUnretainedValue()
            return service.handle(type: type, event: event)
        }

        let eventsOfInterest = CGEventMask(
            (1 << CGEventType.keyDown.rawValue) |
                (1 << CGEventType.keyUp.rawValue) |
                (1 << CGEventType.flagsChanged.rawValue)
        )
        let userInfo = Unmanaged.passUnretained(self).toOpaque()
        let tapCandidates: [(CGEventTapLocation, String)] = [
            (.cghidEventTap, "hid"),
            (.cgSessionEventTap, "session"),
            (.cgAnnotatedSessionEventTap, "annotated-session")
        ]

        var createdEventTapNames: [String] = []
        for candidate in tapCandidates {
            if let eventTap = CGEvent.tapCreate(
                tap: candidate.0,
                place: .headInsertEventTap,
                options: .defaultTap,
                eventsOfInterest: eventsOfInterest,
                callback: callback,
                userInfo: userInfo
            ) {
                guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
                    CFMachPortInvalidate(eventTap)
                    continue
                }
                CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
                CGEvent.tapEnable(tap: eventTap, enable: true)
                eventTaps.append(eventTap)
                runLoopSources.append(runLoopSource)
                createdEventTapNames.append(candidate.1)
            }
        }

        guard !eventTaps.isEmpty else {
            NSLog("AutoComp could not create keyboard event tap; Tab and Right Shift acceptance will not be available.")
            return
        }

        GeometryDebug.log("shortcut-started taps=\(createdEventTapNames.joined(separator: ","))")
    }

    func stop() {
        for runLoopSource in runLoopSources {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }

        for eventTap in eventTaps {
            CGEvent.tapEnable(tap: eventTap, enable: false)
            CFMachPortInvalidate(eventTap)
        }

        eventTaps = []
        runLoopSources = []
        onTab = nil
        onAcceptAll = nil
        onSuggestionTriggerKey = nil
        lastConsumedShortcutKeyCode = nil
        lastConsumedShortcutEventTimestamp = nil
        suppressedKeyReleases = [:]
        state.setSuggestionActive(false)
    }

    func setSuggestionActive(_ active: Bool) {
        state.setSuggestionActive(active)
        GeometryDebug.log("shortcut-active active=\(active) armed=\(state.isShortcutArmed)")
    }

    func clearShortcutGrace() {
        state.clearShortcutGrace()
    }

    func configureHandlers(
        onTab: @escaping () -> Void,
        onAcceptAll: @escaping () -> Void,
        onSuggestionTriggerKey: (() -> Void)? = nil
    ) {
        self.onTab = onTab
        self.onAcceptAll = onAcceptAll
        self.onSuggestionTriggerKey = onSuggestionTriggerKey
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            GeometryDebug.log("shortcut-event-tap-disabled type=\(type.rawValue) reenabled=\(!eventTaps.isEmpty)")
            for eventTap in eventTaps {
                CGEvent.tapEnable(tap: eventTap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .keyUp {
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if shouldSuppressKeyRelease(keyCode: keyCode) {
                GeometryDebug.log("shortcut-keyup-suppressed keyCode=\(keyCode)")
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .flagsChanged {
            return handleFlagsChanged(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let isShortcutKey = keyCode == tabKeyCode
        let isArmed = state.isShortcutArmed
        if isSuggestionTriggerSpace(event, keyCode: keyCode) {
            DispatchQueue.main.async { [weak self] in
                self?.onSuggestionTriggerKey?()
            }
        }
        if isShortcutKey {
            let modifiersOK = hasNoTabModifiers(event)
            GeometryDebug.log("shortcut-key keyCode=\(keyCode) armed=\(isArmed) modifiersOK=\(modifiersOK)")
        }

        guard isArmed else {
            return Unmanaged.passUnretained(event)
        }

        if keyCode == tabKeyCode {
            guard hasNoTabModifiers(event) else {
                return Unmanaged.passUnretained(event)
            }
            guard markShortcutConsumptionIfNeeded(keyCode: keyCode, event: event) else {
                return nil
            }
            suppressKeyRelease(for: keyCode)
            state.extendShortcutGrace(by: shortcutGraceInterval)
            GeometryDebug.log("shortcut-consumed action=tab")
            DispatchQueue.main.async { [weak self] in
                self?.onTab?()
            }
            return nil
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleFlagsChanged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == rightShiftKeyCode else {
            return Unmanaged.passUnretained(event)
        }

        let isRightShiftDown = event.flags.contains(.maskShift)
        if !isRightShiftDown {
            if shouldSuppressKeyRelease(keyCode: keyCode) {
                GeometryDebug.log("shortcut-flags-release-suppressed keyCode=\(keyCode)")
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        let isArmed = state.isShortcutArmed
        let modifiersOK = hasNoAcceptAllModifiers(event)
        GeometryDebug.log("shortcut-modifier keyCode=\(keyCode) armed=\(isArmed) modifiersOK=\(modifiersOK)")

        guard isArmed, modifiersOK else {
            return Unmanaged.passUnretained(event)
        }

        guard markShortcutConsumptionIfNeeded(keyCode: keyCode, event: event) else {
            return nil
        }

        suppressKeyRelease(for: keyCode)
        state.extendShortcutGrace(by: shortcutGraceInterval)
        GeometryDebug.log("shortcut-consumed action=acceptAll")
        DispatchQueue.main.async { [weak self] in
            self?.onAcceptAll?()
        }
        return nil
    }

    private func markShortcutConsumptionIfNeeded(keyCode: UInt16, event: CGEvent) -> Bool {
        consumptionLock.lock()
        defer { consumptionLock.unlock() }

        if event.timestamp > 0,
           lastConsumedShortcutKeyCode == keyCode,
           lastConsumedShortcutEventTimestamp == event.timestamp {
            GeometryDebug.log("shortcut-consumed duplicate-suppressed keyCode=\(keyCode)")
            return false
        }

        lastConsumedShortcutKeyCode = keyCode
        lastConsumedShortcutEventTimestamp = event.timestamp
        return true
    }

    private func suppressKeyRelease(for keyCode: UInt16) {
        consumptionLock.lock()
        defer { consumptionLock.unlock() }

        pruneExpiredSuppressedKeyReleases(now: Date())
        suppressedKeyReleases[keyCode] = Date().addingTimeInterval(keyReleaseSuppressionInterval)
    }

    private func shouldSuppressKeyRelease(keyCode: UInt16) -> Bool {
        consumptionLock.lock()
        defer { consumptionLock.unlock() }

        let now = Date()
        pruneExpiredSuppressedKeyReleases(now: now)
        guard let suppressUntil = suppressedKeyReleases[keyCode],
              now <= suppressUntil else {
            return false
        }
        return true
    }

    private func pruneExpiredSuppressedKeyReleases(now: Date) {
        suppressedKeyReleases = suppressedKeyReleases.filter { $0.value >= now }
    }

    private func hasNoTabModifiers(_ event: CGEvent) -> Bool {
        event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty
    }

    private func hasNoAcceptAllModifiers(_ event: CGEvent) -> Bool {
        event.flags.intersection([.maskCommand, .maskAlternate, .maskControl]).isEmpty
    }

    private func isSuggestionTriggerSpace(_ event: CGEvent, keyCode: UInt16) -> Bool {
        keyCode == spaceKeyCode
            && event.flags.intersection([.maskCommand, .maskAlternate, .maskControl]).isEmpty
    }

}

private final class ShortcutActivationState {
    private let lock = NSLock()
    private var active = false
    private var shortcutGraceUntil: Date = .distantPast

    var isShortcutArmed: Bool {
        lock.lock()
        defer { lock.unlock() }
        return active || Date() <= shortcutGraceUntil
    }

    func setSuggestionActive(_ active: Bool) {
        lock.lock()
        self.active = active
        lock.unlock()
    }

    func extendShortcutGrace(by interval: TimeInterval) {
        lock.lock()
        shortcutGraceUntil = Date().addingTimeInterval(interval)
        lock.unlock()
    }

    func clearShortcutGrace() {
        lock.lock()
        shortcutGraceUntil = .distantPast
        lock.unlock()
    }
}
