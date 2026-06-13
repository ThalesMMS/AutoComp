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

enum ShortcutOwnershipDecision: Equatable, Sendable {
    case consume(reason: String)
    case passThrough(reason: String)

    var shouldConsume: Bool {
        switch self {
        case .consume:
            return true
        case .passThrough:
            return false
        }
    }

    var reason: String {
        switch self {
        case .consume(let reason), .passThrough(let reason):
            return reason
        }
    }

    var diagnosticName: String {
        switch self {
        case .consume:
            return "consume"
        case .passThrough:
            return "pass-through"
        }
    }
}

struct ShortcutOwnershipEvaluator: Sendable {
    func evaluate(
        command: KeyboardShortcutCommand,
        commandDecision: () -> ShortcutOwnershipDecision,
        isSuggestionVisible: Bool,
        inputMethodState: InputMethodState
    ) -> ShortcutOwnershipDecision {
        guard command.requiresActiveSuggestion else {
            return commandDecision()
        }

        guard isSuggestionVisible else {
            return .passThrough(reason: "no-visible-suggestion")
        }

        guard !inputMethodState.shouldPassThroughSuggestionShortcuts else {
            return .passThrough(reason: "input-method")
        }

        return commandDecision()
    }
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
    private var onEmojiCommand: ((EmojiKeyboardCommand) -> Void)?
    private var shortcutOwnershipDecision: (KeyboardShortcutCommand) -> ShortcutOwnershipDecision = { _ in .consume(reason: "default") }
    private let inputEventAdapter = CapturedInputEventAdapter()
    private let inputSuppressionController: InputSuppressionController
    private let inputMethodStateProvider: @Sendable () -> InputMethodState
    private let tapInstaller: KeyboardShortcutTapInstalling
    private var shortcutSettings: KeyboardShortcutSettings
    private var passthroughReplay: (keyCode: UInt16, expiresAt: Date)?
    private var forwardedInputEventIdentities: Set<ForwardedInputEventIdentity> = []
    private var forwardedInputEventIdentityOrder: [ForwardedInputEventIdentity] = []
    private var isInteractionPipelineSuspended = false
    private var isEmojiPickerActive = false
    private let shortcutOwnershipEvaluator = ShortcutOwnershipEvaluator()
    private let shortcutLogger = AutoCompLogger(category: "shortcuts")

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
        onEmojiCommand: ((EmojiKeyboardCommand) -> Void)? = nil,
        shouldInterceptCommand: @escaping (KeyboardShortcutCommand) -> Bool = { _ in true },
        shortcutOwnershipDecision: ((KeyboardShortcutCommand) -> ShortcutOwnershipDecision)? = nil
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
            onEmojiCommand: onEmojiCommand,
            shouldInterceptCommand: shouldInterceptCommand,
            shortcutOwnershipDecision: shortcutOwnershipDecision
        )
    }

    func start(
        onCommand: @escaping (KeyboardShortcutCommand) -> Void,
        onInputEvent: ((CapturedInputEvent) -> Void)? = nil,
        onEmojiCommand: ((EmojiKeyboardCommand) -> Void)? = nil,
        shouldInterceptCommand: @escaping (KeyboardShortcutCommand) -> Bool = { _ in true },
        shortcutOwnershipDecision: ((KeyboardShortcutCommand) -> ShortcutOwnershipDecision)? = nil
    ) {
        configureHandlers(
            onCommand: onCommand,
            onInputEvent: onInputEvent,
            onEmojiCommand: onEmojiCommand,
            shouldInterceptCommand: shouldInterceptCommand,
            shortcutOwnershipDecision: shortcutOwnershipDecision
        )

        let hasPermission = tapInstaller.hasInputMonitoringPermission()
        guard hasPermission else {
            if !eventTaps.isEmpty {
                removeEventTaps()
                passthroughReplay = nil
                resetForwardedInputEventDeduplication()
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
        onEmojiCommand = nil
        shortcutOwnershipDecision = { _ in .consume(reason: "default") }
        passthroughReplay = nil
        resetForwardedInputEventDeduplication()
        isInteractionPipelineSuspended = false
        isEmojiPickerActive = false
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
        guard !isInteractionPipelineSuspended else {
            inputSuppressionController.reset()
            GeometryDebug.log("shortcut-active skipped reason=pipeline-suspended requestedActive=\(active)")
            return
        }
        inputSuppressionController.setSuggestionActive(active)
        GeometryDebug.log("shortcut-active active=\(active) armed=\(inputSuppressionController.isShortcutArmed)")
    }

    var isSuggestionActive: Bool {
        inputSuppressionController.isSuggestionActive
    }

    func setEmojiPickerActive(_ active: Bool) {
        guard isEmojiPickerActive != active else {
            return
        }
        isEmojiPickerActive = active
        GeometryDebug.log("shortcut-emoji-picker-active active=\(active)")
    }

    func clearShortcutGrace() {
        inputSuppressionController.clearShortcutGrace()
    }

    func setInteractionPipelineSuspended(_ suspended: Bool, reason: String) {
        guard isInteractionPipelineSuspended != suspended else {
            return
        }

        isInteractionPipelineSuspended = suspended
        if suspended {
            passthroughReplay = nil
            resetForwardedInputEventDeduplication()
            inputSuppressionController.reset()
        }
        GeometryDebug.log("shortcut-pipeline-suspension suspended=\(suspended) reason=\(reason)")
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
        onEmojiCommand: ((EmojiKeyboardCommand) -> Void)? = nil,
        shouldInterceptCommand: @escaping (KeyboardShortcutCommand) -> Bool = { _ in true },
        shortcutOwnershipDecision: ((KeyboardShortcutCommand) -> ShortcutOwnershipDecision)? = nil
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
            onEmojiCommand: onEmojiCommand,
            shouldInterceptCommand: shouldInterceptCommand,
            shortcutOwnershipDecision: shortcutOwnershipDecision
        )
    }

    func configureHandlers(
        onCommand: @escaping (KeyboardShortcutCommand) -> Void,
        onInputEvent: ((CapturedInputEvent) -> Void)? = nil,
        onEmojiCommand: ((EmojiKeyboardCommand) -> Void)? = nil,
        shouldInterceptCommand: @escaping (KeyboardShortcutCommand) -> Bool = { _ in true },
        shortcutOwnershipDecision: ((KeyboardShortcutCommand) -> ShortcutOwnershipDecision)? = nil
    ) {
        self.onCommand = onCommand
        self.onInputEvent = onInputEvent
        self.onEmojiCommand = onEmojiCommand
        self.shortcutOwnershipDecision = shortcutOwnershipDecision ?? { command in
            shouldInterceptCommand(command)
                ? .consume(reason: "command-enabled")
                : .passThrough(reason: "command-disabled")
        }
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

        if isInteractionPipelineSuspended {
            GeometryDebug.log("shortcut-passthrough reason=pipeline-suspended type=\(type.rawValue)")
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
        logInputCandidate(
            type: type,
            keyCode: keyCode,
            flags: event.flags,
            inputEvent: inputEvent,
            matchedCommand: matchedCommand
        )
        if let emojiCommand = emojiKeyboardCommand(for: inputEvent, matchedCommand: matchedCommand) {
            GeometryDebug.log("shortcut-emoji-picker-consumed command=\(emojiCommand) keyCode=\(keyCode)")
            DispatchQueue.main.async { [weak self] in
                self?.onEmojiCommand?(emojiCommand)
            }
            return nil
        }
        if matchedCommand == nil, let inputEvent {
            dispatchInputEventIfNeeded(inputEvent, inputMethodState: inputMethodState, type: type, event: event)
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
        let inputEvent = capturedInputEvent(type: .flagsChanged, event: event)
        logInputCandidate(
            type: .flagsChanged,
            keyCode: keyCode,
            flags: event.flags,
            inputEvent: inputEvent,
            matchedCommand: matchedCommand
        )
        if matchedCommand == nil,
           inputSuppressionController.consumeSuppressedKeyRelease(keyCode: keyCode) {
            GeometryDebug.log("shortcut-flags-release-suppressed keyCode=\(keyCode)")
            return nil
        }

        guard let matchedCommand else {
            if let inputEvent {
                dispatchInputEventIfNeeded(
                    inputEvent,
                    inputMethodState: inputMethodStateProvider(),
                    type: .flagsChanged,
                    event: event
                )
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
        let ownership = shortcutOwnershipEvaluator.evaluate(
            command: command,
            commandDecision: { shortcutOwnershipDecision(command) },
            isSuggestionVisible: inputSuppressionController.isSuggestionActive,
            inputMethodState: inputMethodState
        )
        logShortcutOwnership(command: command, keyCode: keyCode, decision: ownership)

        guard ownership.shouldConsume else {
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

    private func logShortcutOwnership(
        command: KeyboardShortcutCommand,
        keyCode: UInt16,
        decision: ShortcutOwnershipDecision
    ) {
        let message = "shortcut-ownership decision=\(decision.diagnosticName) command=\(command.rawValue) reason=\(decision.reason) keyCode=\(keyCode)"
        GeometryDebug.log(message)
        shortcutLogger.info(message)
    }

    private func logInputCandidate(
        type: CGEventType,
        keyCode: UInt16,
        flags: CGEventFlags,
        inputEvent: CapturedInputEvent?,
        matchedCommand: KeyboardShortcutCommand?
    ) {
        GeometryDebug.log(
            "shortcut-input type=\(type.keyboardShortcutDebugName) keyCode=\(keyCode) flags=\(modifierFlagsDescription(flags)) inputEvent=\(inputEvent?.debugName ?? "nil") matchedCommand=\(matchedCommand?.rawValue ?? "nil")"
        )
    }

    private func modifierFlagsDescription(_ flags: CGEventFlags) -> String {
        var names: [String] = []
        if flags.contains(.maskCommand) { names.append("command") }
        if flags.contains(.maskAlternate) { names.append("option") }
        if flags.contains(.maskControl) { names.append("control") }
        if flags.contains(.maskShift) { names.append("shift") }
        if flags.contains(.maskSecondaryFn) { names.append("fn") }
        if flags.contains(.maskAlphaShift) { names.append("caps") }
        return names.isEmpty ? "none" : names.joined(separator: ",")
    }

    private func hasNoTabModifiers(_ event: CGEvent) -> Bool {
        event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty
    }

    private func emojiKeyboardCommand(
        for inputEvent: CapturedInputEvent?,
        matchedCommand: KeyboardShortcutCommand?
    ) -> EmojiKeyboardCommand? {
        guard isEmojiPickerActive else {
            return nil
        }

        switch matchedCommand {
        case .acceptNextWord:
            return .acceptSelected
        case .dismissSuggestion:
            return .cancel
        case .selectPreviousSuggestion:
            return .selectPrevious
        case .selectNextSuggestion:
            return .selectNext
        case .acceptFullSuggestion, .manualTrigger, .toggleAutocomplete, nil:
            break
        }

        switch inputEvent {
        case .tab:
            return .acceptSelected
        case .dismissal:
            return .cancel
        case .navigation(let keyCode):
            switch keyCode {
            case 123, 126:
                return .selectPrevious
            case 124, 125:
                return .selectNext
            default:
                return nil
            }
        case .text, .acceptAll, .shortcutMutation, .pointer, nil:
            return nil
        }
    }

    private func dispatchInputEventIfNeeded(
        _ inputEvent: CapturedInputEvent,
        inputMethodState: InputMethodState,
        type: CGEventType,
        event: CGEvent
    ) {
        guard shouldForwardInputEvent(inputEvent, inputMethodState: inputMethodState) else {
            return
        }

        guard shouldForwardUniqueInputEvent(type: type, event: event) else {
            GeometryDebug.log("input-event-duplicate-suppressed eventKind=\(inputEvent.eventKind.rawValue) kind=\(inputEvent.debugName)")
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

        dispatchInputEventIfNeeded(inputEvent, inputMethodState: inputMethodStateProvider(), type: type, event: event)
        return true
    }

    private func shouldForwardUniqueInputEvent(type: CGEventType, event: CGEvent) -> Bool {
        guard let identity = ForwardedInputEventIdentity(type: type, event: event) else {
            return true
        }

        if forwardedInputEventIdentities.contains(identity) {
            return false
        }

        forwardedInputEventIdentities.insert(identity)
        forwardedInputEventIdentityOrder.append(identity)
        pruneForwardedInputEventIdentities()
        return true
    }

    private func pruneForwardedInputEventIdentities() {
        let identityLimit = 32
        guard forwardedInputEventIdentityOrder.count > identityLimit else {
            return
        }

        while forwardedInputEventIdentityOrder.count > identityLimit {
            let oldest = forwardedInputEventIdentityOrder.removeFirst()
            forwardedInputEventIdentities.remove(oldest)
        }
    }

    private func resetForwardedInputEventDeduplication() {
        forwardedInputEventIdentities = []
        forwardedInputEventIdentityOrder = []
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

private struct ForwardedInputEventIdentity: Hashable {
    let typeRawValue: UInt32
    let timestamp: CGEventTimestamp
    let keyCode: Int64
    let flagsRawValue: UInt64
    let mouseButtonNumber: Int64

    init?(type: CGEventType, event: CGEvent) {
        let timestamp = event.timestamp
        guard timestamp > 0 else {
            return nil
        }

        self.typeRawValue = type.rawValue
        self.timestamp = timestamp
        self.flagsRawValue = event.flags.rawValue
        switch type {
        case .keyDown, .keyUp, .flagsChanged:
            self.keyCode = event.getIntegerValueField(.keyboardEventKeycode)
            self.mouseButtonNumber = -1
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            self.keyCode = -1
            self.mouseButtonNumber = event.getIntegerValueField(.mouseEventButtonNumber)
        default:
            self.keyCode = -1
            self.mouseButtonNumber = -1
        }
    }
}

private extension CGEventType {
    var keyboardShortcutDebugName: String {
        switch self {
        case .keyDown:
            "keyDown"
        case .keyUp:
            "keyUp"
        case .flagsChanged:
            "flagsChanged"
        case .leftMouseDown:
            "leftMouseDown"
        case .rightMouseDown:
            "rightMouseDown"
        case .otherMouseDown:
            "otherMouseDown"
        default:
            "\(rawValue)"
        }
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
