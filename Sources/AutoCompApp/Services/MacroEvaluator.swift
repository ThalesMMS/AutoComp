import Foundation

struct LocalMacroEvaluator: InlineCommandEvaluating, @unchecked Sendable {
    private let now: @Sendable () -> Date
    private let calendar: Calendar
    private let locale: Locale

    init(
        now: @escaping @Sendable () -> Date = Date.init,
        calendar: Calendar = .current,
        locale: Locale = .current
    ) {
        self.now = now
        self.calendar = calendar
        self.locale = locale
    }

    func evaluate(_ rawQuery: String) -> MacroEvaluationResult {
        let query = rawQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return .failure(.emptyQuery) }

        if let date = evaluateDate(query) { return date }
        if query.contains("->") || query.range(of: " to ", options: .caseInsensitive) != nil {
            return evaluateUnitConversion(query)
        }
        if query.contains(where: { "+-*/()".contains($0) }) || Double(query) != nil {
            return evaluateArithmetic(query)
        }
        return .failure(.unsupported)
    }

    private func evaluateDate(_ query: String) -> MacroEvaluationResult? {
        let normalized = query.lowercased()
        let dayOffset: Int
        switch normalized {
        case "today": dayOffset = 0
        case "tomorrow": dayOffset = 1
        case "yesterday": dayOffset = -1
        default:
            let pattern = #"^date([+-]\d+)$"#
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                    in: normalized,
                    range: NSRange(normalized.startIndex..<normalized.endIndex, in: normalized)
                  ),
                  let offsetRange = Range(match.range(at: 1), in: normalized),
                  let parsedOffset = Int(normalized[offsetRange]),
                  abs(parsedOffset) <= 36_500 else {
                return nil
            }
            dayOffset = parsedOffset
        }

        guard let date = calendar.date(byAdding: .day, value: dayOffset, to: now()) else {
            return .failure(.invalidExpression)
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = locale
        formatter.timeZone = calendar.timeZone
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        let text = formatter.string(from: date)
        return .value(MacroValue(preview: text, insertionText: text, category: .relativeDate))
    }

    private func evaluateArithmetic(_ query: String) -> MacroEvaluationResult {
        do {
            var parser = ArithmeticParser(query)
            let value = try parser.parse()
            guard value.isFinite else { return .failure(.nonFiniteResult) }
            let text = Self.formatted(value)
            return .value(MacroValue(preview: "= \(text)", insertionText: text, category: .arithmetic))
        } catch let error as MacroEvaluationError {
            return .failure(error)
        } catch {
            return .failure(.invalidExpression)
        }
    }

    private func evaluateUnitConversion(_ query: String) -> MacroEvaluationResult {
        let separatorRange = query.range(of: "->")
            ?? query.range(of: " to ", options: .caseInsensitive)
        guard let separatorRange else { return .failure(.invalidExpression) }
        let left = query[..<separatorRange.lowerBound].trimmingCharacters(in: .whitespaces)
        let target = query[separatorRange.upperBound...].trimmingCharacters(in: .whitespaces).lowercased()
        let pattern = #"^(-?(?:\d+(?:\.\d*)?|\.\d+))\s*([A-Za-z]+)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(
                in: left,
                range: NSRange(left.startIndex..<left.endIndex, in: left)
              ),
              let valueRange = Range(match.range(at: 1), in: left),
              let sourceRange = Range(match.range(at: 2), in: left),
              let value = Double(left[valueRange]) else {
            return .failure(.invalidExpression)
        }
        let source = left[sourceRange].lowercased()
        guard let sourceUnit = Self.units[source], let targetUnit = Self.units[target] else {
            return .failure(.unsupportedUnit)
        }
        guard sourceUnit.dimension == targetUnit.dimension else {
            return .failure(.incompatibleUnits)
        }
        let baseValue = sourceUnit.toBase(value)
        let converted = targetUnit.fromBase(baseValue)
        guard converted.isFinite else { return .failure(.nonFiniteResult) }
        let text = "\(Self.formatted(converted)) \(target)"
        return .value(MacroValue(preview: text, insertionText: text, category: .unitConversion))
    }

    private static func formatted(_ value: Double) -> String {
        let rounded = value.rounded()
        if abs(value - rounded) < 0.000_000_001 {
            return String(format: "%.0f", rounded)
        }
        return String(format: "%.6f", value)
            .replacingOccurrences(of: #"0+$"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\.$"#, with: "", options: .regularExpression)
    }

    private struct UnitDefinition: Sendable {
        let dimension: String
        let toBase: @Sendable (Double) -> Double
        let fromBase: @Sendable (Double) -> Double

        init(dimension: String, scale: Double) {
            self.dimension = dimension
            self.toBase = { $0 * scale }
            self.fromBase = { $0 / scale }
        }

        init(
            dimension: String,
            toBase: @escaping @Sendable (Double) -> Double,
            fromBase: @escaping @Sendable (Double) -> Double
        ) {
            self.dimension = dimension
            self.toBase = toBase
            self.fromBase = fromBase
        }
    }

    private static let units: [String: UnitDefinition] = [
        "mm": .init(dimension: "length", scale: 0.001),
        "cm": .init(dimension: "length", scale: 0.01),
        "m": .init(dimension: "length", scale: 1),
        "km": .init(dimension: "length", scale: 1_000),
        "in": .init(dimension: "length", scale: 0.0254),
        "ft": .init(dimension: "length", scale: 0.3048),
        "yd": .init(dimension: "length", scale: 0.9144),
        "mi": .init(dimension: "length", scale: 1_609.344),
        "g": .init(dimension: "mass", scale: 1),
        "kg": .init(dimension: "mass", scale: 1_000),
        "oz": .init(dimension: "mass", scale: 28.349_523_125),
        "lb": .init(dimension: "mass", scale: 453.592_37),
        "c": .init(dimension: "temperature", toBase: { $0 }, fromBase: { $0 }),
        "f": .init(
            dimension: "temperature",
            toBase: { ($0 - 32) * 5 / 9 },
            fromBase: { $0 * 9 / 5 + 32 }
        )
    ]
}

private struct ArithmeticParser {
    private static let maximumNestingDepth = 64

    private let characters: [Character]
    private var index = 0

    init(_ expression: String) {
        self.characters = Array(expression.filter { !$0.isWhitespace })
    }

    mutating func parse() throws -> Double {
        guard !characters.isEmpty else { throw MacroEvaluationError.invalidExpression }
        let result = try parseExpression(depth: 0)
        guard index == characters.count else { throw MacroEvaluationError.invalidExpression }
        return result
    }

    private mutating func parseExpression(depth: Int) throws -> Double {
        guard depth <= Self.maximumNestingDepth else {
            throw MacroEvaluationError.invalidExpression
        }
        var value = try parseTerm(depth: depth)
        while let operation = peek(), operation == "+" || operation == "-" {
            index += 1
            let right = try parseTerm(depth: depth)
            value = operation == "+" ? value + right : value - right
        }
        return value
    }

    private mutating func parseTerm(depth: Int) throws -> Double {
        var value = try parseFactor(depth: depth)
        while let operation = peek(), operation == "*" || operation == "/" {
            index += 1
            let right = try parseFactor(depth: depth)
            if operation == "/" && right == 0 { throw MacroEvaluationError.nonFiniteResult }
            value = operation == "*" ? value * right : value / right
        }
        return value
    }

    private mutating func parseFactor(depth: Int) throws -> Double {
        guard depth <= Self.maximumNestingDepth else {
            throw MacroEvaluationError.invalidExpression
        }
        if peek() == "+" {
            index += 1
            return try parseFactor(depth: depth + 1)
        }
        if peek() == "-" {
            index += 1
            return -(try parseFactor(depth: depth + 1))
        }
        if peek() == "(" {
            index += 1
            let value = try parseExpression(depth: depth + 1)
            guard peek() == ")" else { throw MacroEvaluationError.invalidExpression }
            index += 1
            return value
        }
        return try parseNumber()
    }

    private mutating func parseNumber() throws -> Double {
        let start = index
        var hasDecimalPoint = false
        while let character = peek(), character.isNumber || character == "." {
            if character == "." {
                guard !hasDecimalPoint else { throw MacroEvaluationError.invalidExpression }
                hasDecimalPoint = true
            }
            index += 1
        }
        guard index > start, let value = Double(String(characters[start..<index])) else {
            throw MacroEvaluationError.invalidExpression
        }
        return value
    }

    private func peek() -> Character? {
        characters.indices.contains(index) ? characters[index] : nil
    }
}
