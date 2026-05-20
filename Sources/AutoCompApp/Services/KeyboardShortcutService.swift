import AppKit
import Foundation

final class KeyboardShortcutService: @unchecked Sendable {
    private var eventTaps: [CFMachPort] = []
    private var runLoopSources: [CFRunLoopSource] = []
    private var onTab: (() -> Void)?
    private var onAcceptAll: (() -> Void)?
    private var onSuggestionTriggerKey: ((CapturedInputEvent) -> Void)?
    private let inputEventAdapter = CapturedInputEventAdapter()
    private let inputSuppressionController: InputSuppressionController

    init(inputSuppressionController: InputSuppressionController = InputSuppressionController()) {
        self.inputSuppressionController = inputSuppressionController
    }

    func start(
        onTab: @escaping () -> Void,
        onAcceptAll: @escaping () -> Void,
        onSuggestionTriggerKey: ((CapturedInputEvent) -> Void)? = nil
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
        inputSuppressionController.reset()
    }

    func setSuggestionActive(_ active: Bool) {
        inputSuppressionController.setSuggestionActive(active)
        GeometryDebug.log("shortcut-active active=\(active) armed=\(inputSuppressionController.isShortcutArmed)")
    }

    func clearShortcutGrace() {
        inputSuppressionController.clearShortcutGrace()
    }

    func configureHandlers(
        onTab: @escaping () -> Void,
        onAcceptAll: @escaping () -> Void,
        onSuggestionTriggerKey: ((CapturedInputEvent) -> Void)? = nil
    ) {
        self.onTab = onTab
        self.onAcceptAll = onAcceptAll
        self.onSuggestionTriggerKey = onSuggestionTriggerKey
    }

    func capturedInputEvent(type: CGEventType, event: CGEvent) -> CapturedInputEvent? {
        inputEventAdapter.event(for: type, event: event)
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
            if inputSuppressionController.shouldSuppressKeyRelease(keyCode: keyCode) {
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
        let inputEvent = capturedInputEvent(type: type, event: event)
        let isShortcutKey = inputEvent == .tab
        let isArmed = inputSuppressionController.isShortcutArmed
        if let inputEvent, inputEvent.isSuggestionTrigger {
            if inputSuppressionController.shouldSuppressSyntheticInput(inputEvent) {
                GeometryDebug.log("suggestion-trigger-suppressed reason=synthetic-input kind=\(inputEvent.debugName)")
            } else {
                DispatchQueue.main.async { [weak self] in
                    self?.onSuggestionTriggerKey?(inputEvent)
                }
            }
        }
        if isShortcutKey {
            let modifiersOK = hasNoTabModifiers(event)
            GeometryDebug.log("shortcut-key keyCode=\(keyCode) armed=\(isArmed) modifiersOK=\(modifiersOK)")
        }

        guard isArmed else {
            return Unmanaged.passUnretained(event)
        }

        if inputEvent == .tab {
            guard hasNoTabModifiers(event) else {
                return Unmanaged.passUnretained(event)
            }
            guard inputSuppressionController.consumeShortcutIfNeeded(
                keyCode: keyCode,
                eventTimestamp: event.timestamp
            ) else {
                return nil
            }
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
        let inputEvent = capturedInputEvent(type: .flagsChanged, event: event)
        guard keyCode == CapturedInputEventAdapter.rightShiftKeyCode else {
            return Unmanaged.passUnretained(event)
        }

        let isRightShiftDown = event.flags.contains(.maskShift)
        if !isRightShiftDown {
            if inputSuppressionController.shouldSuppressKeyRelease(keyCode: keyCode) {
                GeometryDebug.log("shortcut-flags-release-suppressed keyCode=\(keyCode)")
                return nil
            }
            return Unmanaged.passUnretained(event)
        }

        let isArmed = inputSuppressionController.isShortcutArmed
        let modifiersOK = inputEvent == .acceptAll
        GeometryDebug.log("shortcut-modifier keyCode=\(keyCode) armed=\(isArmed) modifiersOK=\(modifiersOK)")

        guard isArmed, modifiersOK else {
            return Unmanaged.passUnretained(event)
        }

        guard inputSuppressionController.consumeShortcutIfNeeded(
            keyCode: keyCode,
            eventTimestamp: event.timestamp
        ) else {
            return nil
        }

        GeometryDebug.log("shortcut-consumed action=acceptAll")
        DispatchQueue.main.async { [weak self] in
            self?.onAcceptAll?()
        }
        return nil
    }

    private func hasNoTabModifiers(_ event: CGEvent) -> Bool {
        event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty
    }

}
