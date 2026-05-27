import AppKit
import Foundation

enum CapturedInputEventKind: String, Equatable, Sendable {
    case acceptance
    case fullAcceptance
    case manualTrigger
    case dismissal
    case textMutation
    case shortcutMutation
    case navigation
    case other
}

enum CapturedInputEvent: Equatable, Sendable {
    case text(keyCode: UInt16, isSuggestionTrigger: Bool)
    case navigation(keyCode: UInt16)
    case dismissal
    case tab
    case acceptAll
    case shortcutMutation(keyCode: UInt16)
    case pointer

    var isSuggestionTrigger: Bool {
        if case .text(_, true) = self {
            return true
        }
        return false
    }

    var eventKind: CapturedInputEventKind {
        switch self {
        case .text:
            return .textMutation
        case .navigation:
            return .navigation
        case .dismissal:
            return .dismissal
        case .tab:
            return .acceptance
        case .acceptAll:
            return .fullAcceptance
        case .shortcutMutation:
            return .shortcutMutation
        case .pointer:
            return .navigation
        }
    }

    var shouldSchedulePrediction: Bool {
        switch self {
        case .text(let keyCode, _):
            return !Self.clearOnlyTextMutationKeyCodes.contains(keyCode)
        case .navigation, .dismissal, .tab, .acceptAll, .shortcutMutation, .pointer:
            return false
        }
    }

    var shouldClearSuggestion: Bool {
        switch self {
        case .text(let keyCode, _):
            return Self.clearOnlyTextMutationKeyCodes.contains(keyCode)
        case .navigation, .dismissal, .shortcutMutation, .pointer:
            return true
        case .tab, .acceptAll:
            return false
        }
    }

    var debugName: String {
        switch self {
        case .text(let keyCode, let isSuggestionTrigger):
            isSuggestionTrigger ? "space" : "text-\(keyCode)"
        case .navigation(let keyCode):
            "navigation-\(keyCode)"
        case .dismissal:
            "dismissal"
        case .tab:
            "tab"
        case .acceptAll:
            "accept-all"
        case .shortcutMutation(let keyCode):
            "shortcut-mutation-\(keyCode)"
        case .pointer:
            "pointer"
        }
    }

    private static let clearOnlyTextMutationKeyCodes: Set<UInt16> = [
        51,  // Delete
        117  // Forward delete
    ]
}

struct CapturedInputEventAdapter {
    static let tabKeyCode: UInt16 = 48
    static let spaceKeyCode: UInt16 = 49
    static let escapeKeyCode: UInt16 = 53
    static let rightShiftKeyCode: UInt16 = 60
    static let arrowKeyCodes: Set<UInt16> = [123, 124, 125, 126]

    func event(for type: CGEventType, event: CGEvent) -> CapturedInputEvent? {
        let keyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))

        switch type {
        case .keyDown:
            return keyDownEvent(keyCode: keyCode, flags: event.flags)
        case .keyUp:
            return .shortcutMutation(keyCode: keyCode)
        case .flagsChanged:
            return flagsChangedEvent(keyCode: keyCode, flags: event.flags)
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            return .pointer
        default:
            return nil
        }
    }

    private func keyDownEvent(keyCode: UInt16, flags: CGEventFlags) -> CapturedInputEvent {
        if keyCode == Self.tabKeyCode {
            return hasNoTabModifiers(flags) ? .tab : .navigation(keyCode: keyCode)
        }

        if keyCode == Self.escapeKeyCode {
            return .dismissal
        }

        if Self.arrowKeyCodes.contains(keyCode) {
            return .navigation(keyCode: keyCode)
        }

        if hasMutationModifiers(flags) {
            return .shortcutMutation(keyCode: keyCode)
        }

        return .text(
            keyCode: keyCode,
            isSuggestionTrigger: keyCode == Self.spaceKeyCode && hasNoTextTriggerModifiers(flags)
        )
    }

    private func flagsChangedEvent(keyCode: UInt16, flags: CGEventFlags) -> CapturedInputEvent {
        if keyCode == Self.rightShiftKeyCode,
           flags.contains(.maskShift),
           hasNoAcceptAllModifiers(flags) {
            return .acceptAll
        }

        return .shortcutMutation(keyCode: keyCode)
    }

    private func hasNoTextTriggerModifiers(_ flags: CGEventFlags) -> Bool {
        flags.intersection([.maskCommand, .maskAlternate, .maskControl]).isEmpty
    }

    private func hasMutationModifiers(_ flags: CGEventFlags) -> Bool {
        !flags.intersection([.maskCommand, .maskAlternate, .maskControl]).isEmpty
    }

    private func hasNoTabModifiers(_ flags: CGEventFlags) -> Bool {
        flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift]).isEmpty
    }

    private func hasNoAcceptAllModifiers(_ flags: CGEventFlags) -> Bool {
        flags.intersection([.maskCommand, .maskAlternate, .maskControl]).isEmpty
    }
}
