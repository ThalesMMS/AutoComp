import Foundation

/// Deterministic validation for keyboard shortcut bindings.
///
/// This is intentionally kept in AutoCompCore so it can be tested without AppKit/event taps.
public enum KeyboardShortcutBindingValidation {
    public typealias CommandID = String

    public struct Binding: Hashable, Sendable {
        public enum Trigger: Hashable, Sendable {
            case keyDown
            case flagsChanged
        }

        public let keyCode: UInt16
        public let modifiers: KeyboardShortcutKeycapFormatter.Modifiers
        public let trigger: Trigger

        public init(
            keyCode: UInt16,
            modifiers: KeyboardShortcutKeycapFormatter.Modifiers = [],
            trigger: Trigger = .keyDown
        ) {
            self.keyCode = keyCode
            self.modifiers = modifiers
            self.trigger = trigger
        }
    }

    public enum Issue: Equatable, Sendable {
        case duplicateBinding(command: CommandID, conflictsWith: CommandID, binding: Binding)
        case reservedBinding(command: CommandID, binding: Binding)

        public var command: CommandID {
            switch self {
            case let .duplicateBinding(command, _, _):
                return command
            case let .reservedBinding(command, _):
                return command
            }
        }
    }

    /// Validates a full command->binding map and returns issues.
    ///
    /// - Parameters:
    ///   - bindings: A full set of bindings keyed by command identifier.
    ///   - commandSortKey: Used for deterministic issue ordering.
    ///   - reservedPredicate: Custom predicate for what counts as reserved/unsafe.
    public static func validate(
        _ bindings: [CommandID: Binding],
        commandSortKey: (CommandID) -> String = { $0 },
        reservedPredicate: (Binding) -> Bool = Self.isReserved
    ) -> [Issue] {
        var issues: [Issue] = []

        // Reserved
        for (command, binding) in bindings {
            if reservedPredicate(binding) {
                issues.append(.reservedBinding(command: command, binding: binding))
            }
        }

        // Duplicates (pairwise by binding)
        var ownersByBinding: [Binding: [CommandID]] = [:]
        for (command, binding) in bindings {
            ownersByBinding[binding, default: []].append(command)
        }

        for (binding, owners) in ownersByBinding {
            guard owners.count > 1 else {
                continue
            }

            let sortedOwners = owners.sorted { commandSortKey($0) < commandSortKey($1) }
            let winner = sortedOwners[0]
            for loser in sortedOwners.dropFirst() {
                issues.append(.duplicateBinding(command: loser, conflictsWith: winner, binding: binding))
            }
        }

        // Deterministic ordering: command, issue type, then binding.
        issues.sort { lhs, rhs in
            let lhsCommand = commandSortKey(lhs.command)
            let rhsCommand = commandSortKey(rhs.command)
            if lhsCommand != rhsCommand {
                return lhsCommand < rhsCommand
            }

            func rank(_ issue: Issue) -> Int {
                switch issue {
                case .reservedBinding:
                    return 0
                case .duplicateBinding:
                    return 1
                }
            }

            let lhsRank = rank(lhs)
            let rhsRank = rank(rhs)
            if lhsRank != rhsRank {
                return lhsRank < rhsRank
            }

            func bindingKey(_ issue: Issue) -> (UInt16, Int, Int) {
                switch issue {
                case let .reservedBinding(_, binding):
                    return (binding.keyCode, binding.modifiers.rawValue, triggerKey(binding.trigger))
                case let .duplicateBinding(_, _, binding):
                    return (binding.keyCode, binding.modifiers.rawValue, triggerKey(binding.trigger))
                }
            }

            return bindingKey(lhs) < bindingKey(rhs)
        }

        return issues
    }

    /// Default reserved/unsafe shortcuts.
    ///
    /// This is intentionally conservative for now. Expand as rules are finalized.
    public static func isReserved(_ binding: Binding) -> Bool {
        // Command-Q (Quit)
        if binding.trigger == .keyDown,
           binding.modifiers == .command,
           binding.keyCode == KeyboardShortcutKeycapFormatter.KnownKeyCodesForValidation.q {
            return true
        }

        // Command-W (Close window)
        if binding.trigger == .keyDown,
           binding.modifiers == .command,
           binding.keyCode == KeyboardShortcutKeycapFormatter.KnownKeyCodesForValidation.w {
            return true
        }

        return false
    }

    private static func triggerKey(_ trigger: Binding.Trigger) -> Int {
        switch trigger {
        case .keyDown:
            return 0
        case .flagsChanged:
            return 1
        }
    }
}

// Keep key codes local to Core (no AppKit dependency).
extension KeyboardShortcutKeycapFormatter {
    enum KnownKeyCodesForValidation {
        static let q: UInt16 = 12
        static let w: UInt16 = 13
    }
}
