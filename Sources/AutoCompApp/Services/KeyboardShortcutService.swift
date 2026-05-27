import AppKit
import AutoCompCore
import Foundation

final class KeyboardShortcutService: @unchecked Sendable {
    private var eventTaps: [CFMachPort] = []
    private var runLoopSources: [CFRunLoopSource] = []
    private var onCommand: ((KeyboardShortcutCommand) -> Void)?
    private var onInputEvent: ((CapturedInputEvent) -> Void)?
    private let inputEventAdapter = CapturedInputEventAdapter()
    private let inputSuppressionController: InputSuppressionController
    private let inputMethodStateProvider: @Sendable () -> InputMethodState
    private var shortcutSettings: KeyboardShortcutSettings
    private var passthroughReplay: (keyCode: UInt16, expiresAt: Date)?

    init(
        inputSuppressionController: InputSuppressionController = InputSuppressionController(),
        shortcutSettings: KeyboardShortcutSettings = .defaults,
        inputMethodStateProvider: @escaping @Sendable () -> InputMethodState = { .asciiCompatible }
    ) {
        self.inputSuppressionController = inputSuppressionController
        self.shortcutSettings = shortcutSettings
        self.inputMethodStateProvider = inputMethodStateProvider
    }

    func start(
        onTab: @escaping () -> Void,
        onAcceptAll: @escaping () -> Void,
        onInputEvent: ((CapturedInputEvent) -> Void)? = nil
    ) {
        start(
            onCommand: { command in
                switch command {
                case .acceptNextWord:
                    onTab()
                case .acceptFullSuggestion:
                    onAcceptAll()
                case .manualTrigger, .dismissSuggestion, .toggleAutocomplete:
                    break
                }
            },
            onInputEvent: onInputEvent
        )
    }

    func start(
        onCommand: @escaping (KeyboardShortcutCommand) -> Void,
        onInputEvent: ((CapturedInputEvent) -> Void)? = nil
    ) {
        stop()
        configureHandlers(
            onCommand: onCommand,
            onInputEvent: onInputEvent
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

        let eventTypes: [CGEventType] = [
            .keyDown,
            .keyUp,
            .flagsChanged,
            .leftMouseDown,
            .rightMouseDown,
            .otherMouseDown
        ]
        let eventsOfInterest = eventTypes.reduce(CGEventMask(0)) { mask, type in
            mask | CGEventMask(1 << type.rawValue)
        }
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
        onCommand = nil
        onInputEvent = nil
        passthroughReplay = nil
        inputSuppressionController.reset()
    }

    func setSuggestionActive(_ active: Bool) {
        inputSuppressionController.setSuggestionActive(active)
        GeometryDebug.log("shortcut-active active=\(active) armed=\(inputSuppressionController.isShortcutArmed)")
    }

    func clearShortcutGrace() {
        inputSuppressionController.clearShortcutGrace()
    }

    func replayPassthroughShortcut(_ command: KeyboardShortcutCommand) {
        let binding = shortcutSettings[command]
        guard binding.trigger == .keyDown else {
            GeometryDebug.log("shortcut-passthrough-replay skipped command=\(command.rawValue) reason=unsupported-trigger")
            return
        }

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(binding.keyCode), keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(binding.keyCode), keyDown: false) else {
            GeometryDebug.log("shortcut-passthrough-replay failed command=\(command.rawValue) reason=event-create")
            return
        }

        inputSuppressionController.clearConsumedShortcut(keyCode: binding.keyCode)
        passthroughReplay = (keyCode: binding.keyCode, expiresAt: Date().addingTimeInterval(0.5))
        keyDown.flags = binding.modifiers.cgEventFlags
        keyUp.flags = binding.modifiers.cgEventFlags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
        GeometryDebug.log("shortcut-passthrough-replay command=\(command.rawValue) keyCode=\(binding.keyCode)")
    }

    func updateShortcutSettings(_ settings: KeyboardShortcutSettings) {
        shortcutSettings = settings
        GeometryDebug.log("shortcut-settings-updated")
    }

    func configureHandlers(
        onTab: @escaping () -> Void,
        onAcceptAll: @escaping () -> Void,
        onInputEvent: ((CapturedInputEvent) -> Void)? = nil
    ) {
        configureHandlers(
            onCommand: { command in
                switch command {
                case .acceptNextWord:
                    onTab()
                case .acceptFullSuggestion:
                    onAcceptAll()
                case .manualTrigger, .dismissSuggestion, .toggleAutocomplete:
                    break
                }
            },
            onInputEvent: onInputEvent
        )
    }

    func configureHandlers(
        onCommand: @escaping (KeyboardShortcutCommand) -> Void,
        onInputEvent: ((CapturedInputEvent) -> Void)? = nil
    ) {
        self.onCommand = onCommand
        self.onInputEvent = onInputEvent
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

        if shouldPassPassthroughReplay(type: type, event: event) {
            return Unmanaged.passUnretained(event)
        }

        if dispatchPassThroughInputEventIfNeeded(type: type, event: event) {
            return Unmanaged.passUnretained(event)
        }

        if type == .keyUp {
            let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            if inputSuppressionController.shouldSuppressKeyRelease(keyCode: keyCode) {
                GeometryDebug.log("shortcut-keyup-suppressed keyCode=\(keyCode)")
                return nil
            }
            if inputSuppressionController.consumeIfSynthetic(type: type, event: event) {
                return Unmanaged.passUnretained(event)
            }
            return Unmanaged.passUnretained(event)
        }

        if type == .flagsChanged {
            return handleFlagsChanged(event)
        }

        guard type == .keyDown else {
            return Unmanaged.passUnretained(event)
        }

        if inputSuppressionController.consumeIfSynthetic(type: type, event: event) {
            return Unmanaged.passUnretained(event)
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let inputEvent = capturedInputEvent(type: type, event: event)
        let inputMethodState = inputMethodStateProvider()
        let matchedCommand = shortcutSettings.command(matching: type, event: event)
        let isShortcutKey = matchedCommand != nil
        let isArmed = inputSuppressionController.isShortcutArmed
        if matchedCommand == nil, let inputEvent {
            dispatchInputEventIfNeeded(inputEvent, inputMethodState: inputMethodState)
        }
        if isShortcutKey {
            let modifiersOK = hasNoTabModifiers(event)
            GeometryDebug.log("shortcut-key keyCode=\(keyCode) armed=\(isArmed) modifiersOK=\(modifiersOK) inputMethod=\(inputMethodState.diagnosticSummary)")
        }

        if let matchedCommand {
            return handleShortcutCommand(
                matchedCommand,
                keyCode: keyCode,
                event: event,
                inputMethodState: inputMethodState,
                isArmed: isArmed
            )
        }

        return Unmanaged.passUnretained(event)
    }

    private func handleFlagsChanged(_ event: CGEvent) -> Unmanaged<CGEvent>? {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let matchedCommand = shortcutSettings.command(matching: .flagsChanged, event: event)
        if matchedCommand == nil,
           inputSuppressionController.shouldSuppressKeyRelease(keyCode: keyCode) {
            GeometryDebug.log("shortcut-flags-release-suppressed keyCode=\(keyCode)")
            return nil
        }

        guard let matchedCommand else {
            if let inputEvent = capturedInputEvent(type: .flagsChanged, event: event) {
                dispatchInputEventIfNeeded(inputEvent, inputMethodState: inputMethodStateProvider())
            }
            return Unmanaged.passUnretained(event)
        }

        let isArmed = inputSuppressionController.isShortcutArmed
        let inputMethodState = inputMethodStateProvider()
        GeometryDebug.log("shortcut-modifier eventKind=\(matchedCommand.inputEventKind.rawValue) keyCode=\(keyCode) command=\(matchedCommand.rawValue) armed=\(isArmed)")

        return handleShortcutCommand(
            matchedCommand,
            keyCode: keyCode,
            event: event,
            inputMethodState: inputMethodState,
            isArmed: isArmed
        )
    }

    private func handleShortcutCommand(
        _ command: KeyboardShortcutCommand,
        keyCode: UInt16,
        event: CGEvent,
        inputMethodState: InputMethodState,
        isArmed: Bool
    ) -> Unmanaged<CGEvent>? {
        GeometryDebug.log("shortcut-command eventKind=\(command.inputEventKind.rawValue) command=\(command.rawValue) keyCode=\(keyCode) armed=\(isArmed)")
        if command.requiresActiveSuggestion {
            guard isArmed else {
                return Unmanaged.passUnretained(event)
            }

            guard !inputMethodState.shouldPassThroughSuggestionShortcuts else {
                GeometryDebug.log("shortcut-pass-through reason=input-method state=\(inputMethodState.diagnosticSummary) source=\(inputMethodState.currentInputSourceID ?? "nil")")
                return Unmanaged.passUnretained(event)
            }
        }

        guard inputSuppressionController.consumeShortcutIfNeeded(
            keyCode: keyCode,
            eventTimestamp: event.timestamp
        ) else {
            return nil
        }

        GeometryDebug.log("shortcut-consumed action=\(command.rawValue)")
        DispatchQueue.main.async { [weak self] in
            self?.onCommand?(command)
        }
        return nil
    }

    private func hasNoTabModifiers(_ event: CGEvent) -> Bool {
        event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty
    }

    private func dispatchInputEventIfNeeded(
        _ inputEvent: CapturedInputEvent,
        inputMethodState: InputMethodState
    ) {
        guard shouldForwardInputEvent(inputEvent, inputMethodState: inputMethodState) else {
            return
        }

        GeometryDebug.log("input-event-forwarded eventKind=\(inputEvent.eventKind.rawValue) kind=\(inputEvent.debugName) schedule=\(inputEvent.shouldSchedulePrediction) clear=\(inputEvent.shouldClearSuggestion)")
        DispatchQueue.main.async { [weak self] in
            self?.onInputEvent?(inputEvent)
        }
    }

    private func shouldForwardInputEvent(
        _ inputEvent: CapturedInputEvent,
        inputMethodState: InputMethodState
    ) -> Bool {
        if inputEvent.shouldSchedulePrediction,
           !inputMethodState.allowsAutomaticSuggestions {
            GeometryDebug.log("input-event-suppressed reason=input-method eventKind=\(inputEvent.eventKind.rawValue) kind=\(inputEvent.debugName) state=\(inputMethodState.diagnosticSummary) source=\(inputMethodState.currentInputSourceID ?? "nil")")
            return false
        }

        return true
    }

    private func dispatchPassThroughInputEventIfNeeded(type: CGEventType, event: CGEvent) -> Bool {
        guard type != .keyDown,
              type != .keyUp,
              type != .flagsChanged,
              let inputEvent = capturedInputEvent(type: type, event: event) else {
            return false
        }

        dispatchInputEventIfNeeded(inputEvent, inputMethodState: inputMethodStateProvider())
        return true
    }

    private func shouldPassPassthroughReplay(type: CGEventType, event: CGEvent) -> Bool {
        guard type == .keyDown || type == .keyUp,
              let replay = passthroughReplay else {
            return false
        }

        guard Date() <= replay.expiresAt else {
            passthroughReplay = nil
            return false
        }

        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard keyCode == replay.keyCode else {
            return false
        }

        if type == .keyUp {
            passthroughReplay = nil
        }
        GeometryDebug.log("shortcut-passthrough-replay-pass type=\(type.rawValue) keyCode=\(keyCode)")
        return true
    }
}

private extension KeyboardShortcutCommand {
    var inputEventKind: CapturedInputEventKind {
        switch self {
        case .acceptNextWord:
            return .acceptance
        case .acceptFullSuggestion:
            return .fullAcceptance
        case .manualTrigger:
            return .manualTrigger
        case .dismissSuggestion:
            return .dismissal
        case .toggleAutocomplete:
            return .other
        }
    }

    var requiresActiveSuggestion: Bool {
        switch self {
        case .acceptNextWord, .acceptFullSuggestion, .dismissSuggestion:
            return true
        case .manualTrigger, .toggleAutocomplete:
            return false
        }
    }
}
