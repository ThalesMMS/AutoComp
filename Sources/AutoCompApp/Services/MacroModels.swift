import AutoCompCore
import Foundation

enum MacroCategory: String, CaseIterable, Codable, Sendable {
    case arithmetic
    case relativeDate = "relative-date"
    case unitConversion = "unit-conversion"

    var displayName: String {
        switch self {
        case .arithmetic: "Arithmetic"
        case .relativeDate: "Relative dates"
        case .unitConversion: "Unit conversion"
        }
    }
}

struct MacroValue: Equatable, Sendable {
    let preview: String
    let insertionText: String
    let category: MacroCategory
}

enum MacroEvaluationError: String, Error, Equatable, Sendable {
    case emptyQuery = "empty-query"
    case invalidExpression = "invalid-expression"
    case unsupportedUnit = "unsupported-unit"
    case incompatibleUnits = "incompatible-units"
    case nonFiniteResult = "non-finite-result"
    case unsupported = "unsupported"
}

enum MacroEvaluationResult: Equatable, Sendable {
    case value(MacroValue)
    case failure(MacroEvaluationError)
}

protocol InlineCommandEvaluating: Sendable {
    func evaluate(_ query: String) -> MacroEvaluationResult
}

struct MacroPreferences: Codable, Equatable, Sendable {
    var isEnabled: Bool = true
}

final class MacroPreferencesStore: @unchecked Sendable {
    private let defaults: MirroredUserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "inlineMacroPreferences") {
        self.defaults = MirroredUserDefaults(primary: defaults)
        self.key = key
    }

    func load() -> MacroPreferences {
        guard let value = defaults.decode(MacroPreferences.self, forKey: key) else {
            return MacroPreferences()
        }
        return value
    }

    func save(_ value: MacroPreferences) throws {
        try defaults.encode(value, forKey: key)
    }
}

struct MacroQueryRun: Equatable, Sendable {
    let query: String
    let literal: String
    let stableFieldIdentity: StableFieldIdentity?
}

struct MacroTriggerStateMachine: Equatable, Sendable {
    private(set) var activeRun: MacroQueryRun?

    mutating func update(
        textBeforeCursor: String,
        stableFieldIdentity: StableFieldIdentity? = nil
    ) -> MacroQueryRun? {
        activeRun = Self.queryRun(
            in: textBeforeCursor,
            stableFieldIdentity: stableFieldIdentity
        )
        return activeRun
    }

    mutating func cancel() {
        activeRun = nil
    }

    static func queryRun(
        in textBeforeCursor: String,
        stableFieldIdentity: StableFieldIdentity? = nil
    ) -> MacroQueryRun? {
        let pattern = #"(^|\s);;([A-Za-z0-9.+\-*/() ]{0,64}(?:(?:->| to )[A-Za-z]{0,12})?)$"#
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let fullRange = NSRange(textBeforeCursor.startIndex..<textBeforeCursor.endIndex, in: textBeforeCursor)
        guard let match = expression.firstMatch(in: textBeforeCursor, range: fullRange),
              let queryRange = Range(match.range(at: 2), in: textBeforeCursor) else {
            return nil
        }
        let boundaryLength = match.range(at: 1).length
        let literalStartUTF16 = match.range(at: 0).location + boundaryLength
        let literalRange = NSRange(
            location: literalStartUTF16,
            length: textBeforeCursor.utf16.count - literalStartUTF16
        )
        guard let literalRange = Range(literalRange, in: textBeforeCursor) else {
            return nil
        }
        return MacroQueryRun(
            query: String(textBeforeCursor[queryRange]),
            literal: String(textBeforeCursor[literalRange]),
            stableFieldIdentity: stableFieldIdentity
        )
    }
}
