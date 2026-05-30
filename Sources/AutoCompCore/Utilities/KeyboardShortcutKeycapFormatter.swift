import Foundation

/// Formats a keyboard shortcut into a compact, UI-friendly "keycap" string.
///
/// This is intended for suggestion overlay hints where space is limited.
///
/// Notes:
/// - This formatter intentionally prefers symbols for modifier keys (⌘⌥⌃⇧) and common
///   special keys (↩⎋⇥␣).
/// - Unknown key codes fall back to a stable string (e.g., "Key 42").
public enum KeyboardShortcutKeycapFormatter {
    public struct Binding: Equatable, Sendable {
        public enum Trigger: Equatable, Sendable {
            case keyDown
            case flagsChanged
        }

        public let keyCode: UInt16
        public let modifiers: Modifiers
        public let trigger: Trigger

        public init(keyCode: UInt16, modifiers: Modifiers = [], trigger: Trigger = .keyDown) {
            self.keyCode = keyCode
            self.modifiers = modifiers
            self.trigger = trigger
        }
    }

    public struct Modifiers: OptionSet, Hashable, Equatable, Sendable {
        public let rawValue: Int

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let control = Modifiers(rawValue: 1 << 2)
        public static let shift = Modifiers(rawValue: 1 << 3)

        public init(rawValue: Int) {
            self.rawValue = rawValue
        }
    }

    public static func format(_ binding: Binding) -> String {
        // Special-case "Right Shift" style bindings which are expressed as a flagsChanged + shift.
        if binding.trigger == .flagsChanged,
           binding.modifiers == .shift,
           binding.keyCode == KnownKeyCodes.rightShift {
            return "Right ⇧"
        }

        let modifierString = formatModifiers(binding.modifiers)
        let keyString = formatKey(binding.keyCode)
        return modifierString + keyString
    }

    public static func formatModifiers(_ modifiers: Modifiers) -> String {
        var result = ""
        if modifiers.contains(.control) {
            result += "⌃"
        }
        if modifiers.contains(.option) {
            result += "⌥"
        }
        if modifiers.contains(.shift) {
            result += "⇧"
        }
        if modifiers.contains(.command) {
            result += "⌘"
        }
        return result
    }

    public static func formatKey(_ keyCode: UInt16) -> String {
        switch keyCode {
        case KnownKeyCodes.tab:
            return "⇥"
        case KnownKeyCodes.returnKey:
            return "↩"
        case KnownKeyCodes.escape:
            return "⎋"
        case KnownKeyCodes.space:
            return "␣"
        case KnownKeyCodes.upArrow:
            return "↑"
        case KnownKeyCodes.downArrow:
            return "↓"
        case KnownKeyCodes.leftArrow:
            return "←"
        case KnownKeyCodes.rightArrow:
            return "→"
        default:
            return fallbackKeyLabel(for: keyCode)
        }
    }

    private static func fallbackKeyLabel(for keyCode: UInt16) -> String {
        // Minimal mapping for common US keyboard codes we rely on in defaults.
        switch keyCode {
        case 0: return "A"
        case 11: return "B"
        case 8: return "C"
        case 2: return "D"
        case 14: return "E"
        case 3: return "F"
        case 5: return "G"
        case 4: return "H"
        case 34: return "I"
        case 38: return "J"
        case 40: return "K"
        case 37: return "L"
        case 46: return "M"
        case 45: return "N"
        case 31: return "O"
        case 35: return "P"
        case 12: return "Q"
        case 15: return "R"
        case 1: return "S"
        case 17: return "T"
        case 32: return "U"
        case 9: return "V"
        case 13: return "W"
        case 7: return "X"
        case 16: return "Y"
        case 6: return "Z"

        case 18: return "1"
        case 19: return "2"
        case 20: return "3"
        case 21: return "4"
        case 23: return "5"
        case 22: return "6"
        case 26: return "7"
        case 28: return "8"
        case 25: return "9"
        case 29: return "0"

        case 50: return "`"
        case 33: return "["
        case 30: return "]"
        default:
            return "Key \(keyCode)"
        }
    }

    /// Key codes are from macOS virtual key codes.
    public enum KnownKeyCodes {
        public static let tab: UInt16 = 48
        public static let returnKey: UInt16 = 36
        public static let escape: UInt16 = 53
        public static let space: UInt16 = 49

        public static let leftArrow: UInt16 = 123
        public static let rightArrow: UInt16 = 124
        public static let downArrow: UInt16 = 125
        public static let upArrow: UInt16 = 126

        public static let rightShift: UInt16 = 60
    }
}
