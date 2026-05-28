import AppKit
import Foundation

enum KeyboardShortcutCommand: String, CaseIterable, Codable, Identifiable, Sendable {
    case acceptNextWord
    case acceptFullSuggestion
    case selectPreviousSuggestion
    case selectNextSuggestion
    case manualTrigger
    case dismissSuggestion
    case toggleAutocomplete

    var id: String { rawValue }

    var title: String {
        switch self {
        case .acceptNextWord:
            return "Accept next word"
        case .acceptFullSuggestion:
            return "Accept full suggestion"
        case .selectPreviousSuggestion:
            return "Previous suggestion"
        case .selectNextSuggestion:
            return "Next suggestion"
        case .manualTrigger:
            return "Manual trigger"
        case .dismissSuggestion:
            return "Dismiss suggestion"
        case .toggleAutocomplete:
            return "Toggle AutoComp"
        }
    }
}

enum KeyboardShortcutTrigger: String, Codable, Sendable {
    case keyDown
    case flagsChanged

    func matches(_ type: CGEventType) -> Bool {
        switch self {
        case .keyDown:
            return type == .keyDown
        case .flagsChanged:
            return type == .flagsChanged
        }
    }
}

struct KeyboardShortcutModifiers: OptionSet, Codable, Equatable, Sendable {
    let rawValue: Int

    static let command = KeyboardShortcutModifiers(rawValue: 1 << 0)
    static let option = KeyboardShortcutModifiers(rawValue: 1 << 1)
    static let control = KeyboardShortcutModifiers(rawValue: 1 << 2)
    static let shift = KeyboardShortcutModifiers(rawValue: 1 << 3)

    init(rawValue: Int) {
        self.rawValue = rawValue
    }

    init(cgEventFlags: CGEventFlags) {
        var modifiers: KeyboardShortcutModifiers = []
        if cgEventFlags.contains(.maskCommand) {
            modifiers.insert(.command)
        }
        if cgEventFlags.contains(.maskAlternate) {
            modifiers.insert(.option)
        }
        if cgEventFlags.contains(.maskControl) {
            modifiers.insert(.control)
        }
        if cgEventFlags.contains(.maskShift) {
            modifiers.insert(.shift)
        }
        self = modifiers
    }

    init(nsEventFlags: NSEvent.ModifierFlags) {
        let flags = nsEventFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: KeyboardShortcutModifiers = []
        if flags.contains(.command) {
            modifiers.insert(.command)
        }
        if flags.contains(.option) {
            modifiers.insert(.option)
        }
        if flags.contains(.control) {
            modifiers.insert(.control)
        }
        if flags.contains(.shift) {
            modifiers.insert(.shift)
        }
        self = modifiers
    }

    var displayParts: [String] {
        var parts: [String] = []
        if contains(.command) {
            parts.append("Command")
        }
        if contains(.option) {
            parts.append("Option")
        }
        if contains(.control) {
            parts.append("Control")
        }
        if contains(.shift) {
            parts.append("Shift")
        }
        return parts
    }

    var cgEventFlags: CGEventFlags {
        var flags: CGEventFlags = []
        if contains(.command) {
            flags.insert(.maskCommand)
        }
        if contains(.option) {
            flags.insert(.maskAlternate)
        }
        if contains(.control) {
            flags.insert(.maskControl)
        }
        if contains(.shift) {
            flags.insert(.maskShift)
        }
        return flags
    }
}

struct KeyboardShortcutBinding: Codable, Equatable, Sendable {
    let keyCode: UInt16
    let modifiers: KeyboardShortcutModifiers
    let trigger: KeyboardShortcutTrigger

    init(
        keyCode: UInt16,
        modifiers: KeyboardShortcutModifiers = [],
        trigger: KeyboardShortcutTrigger = .keyDown
    ) {
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.trigger = trigger
    }

    init(event: NSEvent, trigger: KeyboardShortcutTrigger) {
        self.init(
            keyCode: UInt16(event.keyCode),
            modifiers: KeyboardShortcutModifiers(nsEventFlags: event.modifierFlags),
            trigger: trigger
        )
    }

    func matches(type: CGEventType, event: CGEvent) -> Bool {
        guard trigger.matches(type) else {
            return false
        }

        let eventKeyCode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        guard eventKeyCode == keyCode else {
            return false
        }

        return KeyboardShortcutModifiers(cgEventFlags: event.flags) == modifiers
    }

    var displayName: String {
        if trigger == .flagsChanged,
           keyCode == CapturedInputEventAdapter.rightShiftKeyCode,
           modifiers == .shift {
            return "Right Shift"
        }

        let parts = modifiers.displayParts + [Self.keyName(for: keyCode)]
        return parts.joined(separator: "-")
    }

    private static func keyName(for keyCode: UInt16) -> String {
        switch keyCode {
        case 0:
            return "A"
        case CapturedInputEventAdapter.tabKeyCode:
            return "Tab"
        case CapturedInputEventAdapter.spaceKeyCode:
            return "Space"
        case 50:
            return "`"
        case CapturedInputEventAdapter.leftBracketKeyCode:
            return "["
        case CapturedInputEventAdapter.rightBracketKeyCode:
            return "]"
        case CapturedInputEventAdapter.escapeKeyCode:
            return "Esc"
        case 125:
            return "Down Arrow"
        case 126:
            return "Up Arrow"
        case CapturedInputEventAdapter.rightShiftKeyCode:
            return "Right Shift"
        default:
            return "Key \(keyCode)"
        }
    }
}

struct KeyboardShortcutSettings: Codable, Equatable, Sendable {
    var acceptNextWord: KeyboardShortcutBinding
    var acceptFullSuggestion: KeyboardShortcutBinding
    var selectPreviousSuggestion: KeyboardShortcutBinding
    var selectNextSuggestion: KeyboardShortcutBinding
    var manualTrigger: KeyboardShortcutBinding
    var dismissSuggestion: KeyboardShortcutBinding
    var toggleAutocomplete: KeyboardShortcutBinding

    private enum CodingKeys: String, CodingKey {
        case acceptNextWord
        case acceptFullSuggestion
        case selectPreviousSuggestion
        case selectNextSuggestion
        case manualTrigger
        case dismissSuggestion
        case toggleAutocomplete
    }

    init(
        acceptNextWord: KeyboardShortcutBinding = Self.defaultAcceptNextWord,
        acceptFullSuggestion: KeyboardShortcutBinding = Self.defaultAcceptFullSuggestion,
        selectPreviousSuggestion: KeyboardShortcutBinding = Self.defaultSelectPreviousSuggestion,
        selectNextSuggestion: KeyboardShortcutBinding = Self.defaultSelectNextSuggestion,
        manualTrigger: KeyboardShortcutBinding = Self.defaultManualTrigger,
        dismissSuggestion: KeyboardShortcutBinding = Self.defaultDismissSuggestion,
        toggleAutocomplete: KeyboardShortcutBinding = Self.defaultToggleAutocomplete
    ) {
        self.acceptNextWord = acceptNextWord
        self.acceptFullSuggestion = acceptFullSuggestion
        self.selectPreviousSuggestion = selectPreviousSuggestion
        self.selectNextSuggestion = selectNextSuggestion
        self.manualTrigger = manualTrigger
        self.dismissSuggestion = dismissSuggestion
        self.toggleAutocomplete = toggleAutocomplete
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            acceptNextWord: try container.decodeIfPresent(KeyboardShortcutBinding.self, forKey: .acceptNextWord) ?? Self.defaultAcceptNextWord,
            acceptFullSuggestion: try container.decodeIfPresent(KeyboardShortcutBinding.self, forKey: .acceptFullSuggestion) ?? Self.defaultAcceptFullSuggestion,
            selectPreviousSuggestion: try container.decodeIfPresent(KeyboardShortcutBinding.self, forKey: .selectPreviousSuggestion) ?? Self.defaultSelectPreviousSuggestion,
            selectNextSuggestion: try container.decodeIfPresent(KeyboardShortcutBinding.self, forKey: .selectNextSuggestion) ?? Self.defaultSelectNextSuggestion,
            manualTrigger: try container.decodeIfPresent(KeyboardShortcutBinding.self, forKey: .manualTrigger) ?? Self.defaultManualTrigger,
            dismissSuggestion: try container.decodeIfPresent(KeyboardShortcutBinding.self, forKey: .dismissSuggestion) ?? Self.defaultDismissSuggestion,
            toggleAutocomplete: try container.decodeIfPresent(KeyboardShortcutBinding.self, forKey: .toggleAutocomplete) ?? Self.defaultToggleAutocomplete
        )
    }

    static let defaults = KeyboardShortcutSettings()

    static let defaultAcceptNextWord = KeyboardShortcutBinding(
        keyCode: CapturedInputEventAdapter.tabKeyCode
    )
    static let defaultAcceptFullSuggestion = KeyboardShortcutBinding(
        keyCode: CapturedInputEventAdapter.rightShiftKeyCode,
        modifiers: .shift,
        trigger: .flagsChanged
    )
    static let defaultSelectPreviousSuggestion = KeyboardShortcutBinding(
        keyCode: CapturedInputEventAdapter.leftBracketKeyCode,
        modifiers: .option
    )
    static let defaultSelectNextSuggestion = KeyboardShortcutBinding(
        keyCode: CapturedInputEventAdapter.rightBracketKeyCode,
        modifiers: .option
    )
    static let defaultManualTrigger = KeyboardShortcutBinding(
        keyCode: CapturedInputEventAdapter.spaceKeyCode,
        modifiers: .option
    )
    static let defaultDismissSuggestion = KeyboardShortcutBinding(
        keyCode: CapturedInputEventAdapter.escapeKeyCode
    )
    static let defaultToggleAutocomplete = KeyboardShortcutBinding(
        keyCode: 0,
        modifiers: [.command, .option, .control]
    )

    subscript(command: KeyboardShortcutCommand) -> KeyboardShortcutBinding {
        get {
            switch command {
            case .acceptNextWord:
                return acceptNextWord
            case .acceptFullSuggestion:
                return acceptFullSuggestion
            case .selectPreviousSuggestion:
                return selectPreviousSuggestion
            case .selectNextSuggestion:
                return selectNextSuggestion
            case .manualTrigger:
                return manualTrigger
            case .dismissSuggestion:
                return dismissSuggestion
            case .toggleAutocomplete:
                return toggleAutocomplete
            }
        }
        set {
            switch command {
            case .acceptNextWord:
                acceptNextWord = newValue
            case .acceptFullSuggestion:
                acceptFullSuggestion = newValue
            case .selectPreviousSuggestion:
                selectPreviousSuggestion = newValue
            case .selectNextSuggestion:
                selectNextSuggestion = newValue
            case .manualTrigger:
                manualTrigger = newValue
            case .dismissSuggestion:
                dismissSuggestion = newValue
            case .toggleAutocomplete:
                toggleAutocomplete = newValue
            }
        }
    }

    func command(matching type: CGEventType, event: CGEvent) -> KeyboardShortcutCommand? {
        KeyboardShortcutCommand.allCases.first { command in
            self[command].matches(type: type, event: event)
        }
    }
}

final class KeyboardShortcutSettingsStore: @unchecked Sendable {
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "keyboardShortcuts") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> KeyboardShortcutSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(KeyboardShortcutSettings.self, from: data) else {
            return .defaults
        }
        return settings
    }

    func save(_ settings: KeyboardShortcutSettings) {
        guard let data = try? JSONEncoder().encode(settings) else {
            return
        }
        defaults.set(data, forKey: key)
    }
}
