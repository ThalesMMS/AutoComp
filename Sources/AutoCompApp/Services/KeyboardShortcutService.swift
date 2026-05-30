import AppKit
import AutoCompCore
import Foundation

struct KeyboardShortcutServiceDiagnostics: Equatable {
    let activeTapCount: Int
    let activeTapNames: [String]
    let handlersConfigured: Bool

    var activeTapSetCount: Int {
        activeTapCount > 0 ? 1 : 0
    }
}

protocol KeyboardShortcutTap: AnyObject {
    var name: String { get }
    func enable(_ enabled: Bool)
    func invalidate()
    func removeFromRunLoop()
}

protocol KeyboardShortcutTapInstalling: AnyObject {
    func hasInputMonitoringPermission() -> Bool
    func installTap(
        location: CGEventTapLocation,
        name: String,
        eventsOfInterest: CGEventMask,
        callback: @escaping CGEventTapCallBack,
        userInfo: UnsafeMutableRawPointer
    ) -> KeyboardShortcutTap?
}

final class SystemKeyboardShortcutTapInstaller: KeyboardShortcutTapInstalling {
    func hasInputMonitoringPermission() -> Bool {
        CGPreflightListenEventAccess()
    }

    func installTap(
        location: CGEventTapLocation,
        name: String,
        eventsOfInterest: CGEventMask,
        callback: @escaping CGEventTapCallBack,
        userInfo: UnsafeMutableRawPointer
    ) -> KeyboardShortcutTap? {
        guard let eventTap = CGEvent.tapCreate(
            tap: location,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: eventsOfInterest,
            callback: callback,
            userInfo: userInfo
        ) else {
            return nil
        }

        guard let runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, eventTap, 0) else {
            CFMachPortInvalidate(eventTap)
            return nil
        }

        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: eventTap, enable: true)
        return SystemKeyboardShortcutTap(name: name, eventTap: eventTap, runLoopSource: runLoopSource)
    }
}

private final class SystemKeyboardShortcutTap: KeyboardShortcutTap {
    let name: String
    private let eventTap: CFMachPort
    private let runLoopSource: CFRunLoopSource

    init(name: String, eventTap: CFMachPort, runLoopSource: CFRunLoopSource) {
        self.name = name
        self.eventTap = eventTap
        self.runLoopSource = runLoopSource
    }

    func enable(_ enabled: Bool) {
        CGEvent.tapEnable(tap: eventTap, enable: enabled)
    }

    func invalidate() {
        CFMachPortInvalidate(eventTap)
    }

    func removeFromRunLoop() {
        CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
    }
}

final class KeyboardShortcutService: @unchecked Sendable {
    private var eventTaps: [KeyboardShortcutTap] = []
    private var onCommand: ((KeyboardShortcutCommand) -> Void)?
    private var onInputEvent: ((CapturedInputEvent) -> Void)?
    private var shouldInterceptCommand: (KeyboardShortcutCommand) -> Bool = { _ in true }
    private let inputEventAdapter = CapturedInputEventAdapter()
    private let inputSuppressionController: InputSuppressionController
    private let inputMethodStateProvider: @Sendable () -> InputMethodState
    private let tapInstaller: KeyboardShortcutTapInstalling
    private var shortcutSettings: KeyboardShortcutSettings
    private var passthroughReplay: (keyCode: UInt16, expiresAt: Date)?

    init(
        inputSuppressionController: InputSuppressionController = InputSuppressionController(),
        shortcutSettings: KeyboardShortcutSettings = .defaults,
        inputMethodStateProvider: @escaping @Sendable () -> InputMethodState = { .asciiCompatible },
        tapInstaller: KeyboardShortcutTapInstalling = SystemKeyboardShortcutTapInstaller()
    ) {
        self.inputSuppressionController = inputSuppressionController
        self.shortcutSettings = shortcutSettings
        self.inputMethodStateProvider = inputMethodStateProvider
        self.tapInstaller = tapInstaller
    }

    var diagnostics: KeyboardShortcutServiceDiagnostics {
        KeyboardShortcutServiceDiagnostics(
            activeTapCount: eventTaps.count,
            activeTapNames: eventTaps.map(\.name),
            handlersConfigured: onCommand != nil
        )
    }

    func start(
        onTab: @escaping () -> Void,
        onAcceptAll: @escaping () -> Void,
        onInputEvent: ((CapturedInputEvent) -> Void)? = nil,
        shouldInterceptCommand: @escaping (KeyboardShortcutCommand) -> Bool = { _ in true }
    ) {
        start(
            onCommand: { command in
                switch command {
                case .acceptNextWord:
                    onTab()
                case .acceptFullSuggestion:
                    onAcceptAll()
                case .selectPreviousSuggestion, .selectNextSuggestion, .manualTrigger, .dismissSuggestion, .toggleAutocomplete:
                    break
                }
            },
            onInputEvent: onInputEvent,
            shouldInterceptCommand: shouldInterceptCommand
        )
    }

    func start(
        onCommand: @escaping (KeyboardShortcutCommand) -> Void,
        onInputEvent: ((CapturedInputEvent) -> Void)? = nil,
        shouldInterceptCommand: @escaping (KeyboardShortcutCommand) -> Bool = { _ in true }
    ) {
        configureHandlers(
            onCommand: onCommand,
            onInputEvent: onInputEvent,
            shouldInterceptCommand: shouldInterceptCommand
        )

        let hasPermission = tapInstaller.hasInputMonitoringPermission()
        guard hasPermission else {
            if !eventTaps.isEmpty {
                removeEventTaps()
                passthroughReplay = nil
                inputSuppressionController.reset()
            }
            NSLog("AutoComp cannot monitor keyboard shortcuts until Input Monitoring permission is enabled.")
            GeometryDebug.log("shortcut-start rejected reason=input-monitoring-missing")
            return
        }

        guard eventTaps.isEmpty else {
            GeometryDebug.log("shortcut-start skipped reason=already-running taps=\(eventTaps.map(\.name).joined(separator: ","))")
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
            if let eventTap = tapInstaller.installTap(
                location: candidate.0,
                name: candidate.1,
                eventsOfInterest: eventsOfInterest,
                callback: callback,
                userInfo: userInfo
            ) {
                eventTaps.append(eventTap)
                createdEventTapNames.append(eventTap.name)
            }
        }

        guard !eventTaps.isEmpty else {
            NSLog("AutoComp could not create keyboard event tap; Tab and Right Shift acceptance will not be available.")
            return
        }

        GeometryDebug.log("shortcut-started taps=\(createdEventTapNames.joined(separator: ","))")
    }

    func stop() {
        removeEventTaps()
        onCommand = nil
        onInputEvent = nil
        shouldInterceptCommand = { _ in true }
        passthroughReplay = nil
        inputSuppressionController.reset()
    }

    private func removeEventTaps() {
        for eventTap in eventTaps {
            eventTap.removeFromRunLoop()
            eventTap.enable(false)
            eventTap.invalidate()
        }

        eventTaps = []
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
        onInputEvent: ((CapturedInputEvent) -> Void)? = nil,
        shouldInterceptCommand: @escaping (KeyboardShortcutCommand) -> Bool = { _ in true }
    ) {
        configureHandlers(
            onCommand: { command in
                switch command {
                case .acceptNextWord:
                    onTab()
                case .acceptFullSuggestion:
                    onAcceptAll()
                case .selectPreviousSuggestion, .selectNextSuggestion, .manualTrigger, .dismissSuggestion, .toggleAutocomplete:
                    break
                }
            },
            onInputEvent: onInputEvent,
            shouldInterceptCommand: shouldInterceptCommand
        )
    }

    func configureHandlers(
        onCommand: @escaping (KeyboardShortcutCommand) -> Void,
        onInputEvent: ((CapturedInputEvent) -> Void)? = nil,
        shouldInterceptCommand: @escaping (KeyboardShortcutCommand) -> Bool = { _ in true }
    ) {
        self.onCommand = onCommand
        self.onInputEvent = onInputEvent
        self.shouldInterceptCommand = shouldInterceptCommand
    }

    func capturedInputEvent(type: CGEventType, event: CGEvent) -> CapturedInputEvent? {
        inputEventAdapter.event(for: type, event: event)
    }

    func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            GeometryDebug.log("shortcut-event-tap-disabled type=\(type.rawValue) reenabled=\(!eventTaps.isEmpty)")
            for eventTap in eventTaps {
                eventTap.enable(true)
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
            if inputSuppressionController.consumeSuppressedKeyRelease(keyCode: keyCode) {
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
           inputSuppressionController.consumeSuppressedKeyRelease(keyCode: keyCode) {
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
                GeometryDebug.log("shortcut-pass-through reason=inactive command=\(command.rawValue) keyCode=\(keyCode)")
                return Unmanaged.passUnretained(event)
            }

            guard !inputMethodState.shouldPassThroughSuggestionShortcuts else {
                GeometryDebug.log("shortcut-pass-through reason=input-method state=\(inputMethodState.diagnosticSummary) source=\(inputMethodState.currentInputSourceID ?? "nil")")
                return Unmanaged.passUnretained(event)
            }
        }

        guard shouldInterceptCommand(command) else {
            GeometryDebug.log("shortcut-pass-through reason=command-disabled command=\(command.rawValue)")
            return Unmanaged.passUnretained(event)
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
        case .selectPreviousSuggestion, .selectNextSuggestion:
            return .navigation
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
        case .acceptNextWord, .acceptFullSuggestion, .selectPreviousSuggestion, .selectNextSuggestion, .dismissSuggestion:
            return true
        case .manualTrigger, .toggleAutocomplete:
            return false
        }
    }
}
