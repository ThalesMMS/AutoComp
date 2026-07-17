@testable import AutoCompApp
import XCTest

final class MacroEvaluatorTests: XCTestCase {
    func testArithmeticUsesPrecedenceParenthesesAndUnaryOperators() {
        let evaluator = LocalMacroEvaluator()

        XCTAssertEqual(
            evaluator.evaluate("2 + 3 * 4"),
            .value(MacroValue(preview: "= 14", insertionText: "14", category: .arithmetic))
        )
        XCTAssertEqual(
            evaluator.evaluate("-(2 + 3) / 2"),
            .value(MacroValue(preview: "= -2.5", insertionText: "-2.5", category: .arithmetic))
        )
        XCTAssertEqual(evaluator.evaluate("1 / 0"), .failure(.nonFiniteResult))
        XCTAssertEqual(evaluator.evaluate("2 + )"), .failure(.invalidExpression))
    }

    func testArithmeticRejectsExcessiveUnaryAndParenthesisDepth() {
        let evaluator = LocalMacroEvaluator()

        XCTAssertEqual(
            evaluator.evaluate(String(repeating: "-", count: 1_000) + "1"),
            .failure(.invalidExpression)
        )
        XCTAssertEqual(
            evaluator.evaluate(
                String(repeating: "(", count: 1_000)
                    + "1"
                    + String(repeating: ")", count: 1_000)
            ),
            .failure(.invalidExpression)
        )
    }

    func testRelativeDatesUseInjectedClockCalendarAndLocale() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 7, day: 12)))
        let evaluator = LocalMacroEvaluator(
            now: { now },
            calendar: calendar,
            locale: Locale(identifier: "en_US_POSIX")
        )

        XCTAssertEqual(
            evaluator.evaluate("tomorrow"),
            .value(MacroValue(preview: "Jul 13, 2026", insertionText: "Jul 13, 2026", category: .relativeDate))
        )
        XCTAssertEqual(
            evaluator.evaluate("date-2"),
            .value(MacroValue(preview: "Jul 10, 2026", insertionText: "Jul 10, 2026", category: .relativeDate))
        )
    }

    func testUnitConversionsAreLocalAndRejectIncompatibleDimensions() {
        let evaluator = LocalMacroEvaluator()

        XCTAssertEqual(
            evaluator.evaluate("10 km -> mi"),
            .value(MacroValue(preview: "6.213712 mi", insertionText: "6.213712 mi", category: .unitConversion))
        )
        XCTAssertEqual(
            evaluator.evaluate("32f to c"),
            .value(MacroValue(preview: "0 c", insertionText: "0 c", category: .unitConversion))
        )
        XCTAssertEqual(evaluator.evaluate("1kg -> m"), .failure(.incompatibleUnits))
        XCTAssertEqual(evaluator.evaluate("1parsec -> m"), .failure(.unsupportedUnit))
    }

    func testUnsupportedQueryReturnsStructuredFailure() {
        XCTAssertEqual(LocalMacroEvaluator().evaluate("weather"), .failure(.unsupported))
    }
}
