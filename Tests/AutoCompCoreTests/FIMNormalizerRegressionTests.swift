import AutoCompCore
import Foundation
import XCTest

final class FIMNormalizerRegressionTests: XCTestCase {
    func testMinimizedRegressionFixturesNormalizeToInsertableText() throws {
        let fixtures = try loadFixtures()
        XCTAssertEqual(Set(fixtures.map(\.name)).count, fixtures.count)
        XCTAssertTrue(
            fixtures.contains { $0.source == "minimized-deterministic-fuzz" },
            "Random or fuzz failures should be minimized into deterministic fixtures."
        )

        for fixture in fixtures {
            let request = makeRequest(for: fixture)
            let normalized = SuggestionTextNormalizer.normalize(
                rawText: fixture.rawText,
                request: request
            )

            XCTAssertEqual(request.mode, .fillInMiddle, fixture.name)
            XCTAssertEqual(normalized, fixture.expectedText, fixture.name)
            assertInsertable(normalized, request: request, fixtureName: fixture.name)
        }
    }

    func testRegressionFixturesCoverRequiredFIMAndNormalizerClasses() throws {
        let categories = Set(try loadFixtures().flatMap(\.categories))
        let requiredCategories: Set<String> = [
            "shortSuffix",
            "longSuffix",
            "selection",
            "manualOnly",
            "suffixEcho",
            "prefixAndSuffixEcho",
            "explanatoryOutput",
            "markdownFence",
            "newline",
            "mixedLanguage",
            "combiningMark",
            "graphemeCluster",
            "xmlLikeTags",
            "chatTags",
            "suffixAtStart"
        ]

        XCTAssertTrue(
            categories.isSuperset(of: requiredCategories),
            "Missing categories: \(requiredCategories.subtracting(categories).sorted())"
        )
    }

    func testDeterministicFuzzMatrixKeepsOutputInsertable() {
        var generator = SeededGenerator(seed: 0xA11C_0F1A)
        let prefixes = [
            "A reuniao foi ",
            "The rollout ",
            "Resultado: ",
            "Please "
        ]
        let insertions = [
            "adiada",
            "can proceed",
            "cafe\u{301}",
            "👩🏽‍💻"
        ]
        let suffixes = [
            " porque o prazo mudou.",
            " after review.",
            " agora.",
            " for Friday."
        ]
        let patterns = FuzzPattern.allCases

        for index in 0..<96 {
            let prefix = prefixes[generator.nextIndex(upperBound: prefixes.count)]
            let insertion = insertions[generator.nextIndex(upperBound: insertions.count)]
            let suffix = suffixes[generator.nextIndex(upperBound: suffixes.count)]
            let pattern = patterns[generator.nextIndex(upperBound: patterns.count)]
            let context = makeContext(
                textBeforeCursor: prefix,
                textAfterCursor: suffix,
                fullTextWindow: "\(prefix)\(suffix)"
            )
            let request = makeRequest(for: context)
            let rawText = pattern.rawText(
                prefix: prefix,
                insertion: insertion,
                suffix: suffix
            )

            let normalized = SuggestionTextNormalizer.normalize(
                rawText: rawText,
                request: request
            )

            XCTAssertEqual(normalized, insertion, "fuzz index \(index), pattern \(pattern)")
            assertInsertable(normalized, request: request, fixtureName: "fuzz index \(index)")
        }
    }

    func testActiveSelectionFixtureBlocksAutomaticButAllowsManualReplacement() throws {
        let fixture = try XCTUnwrap(
            loadFixtures().first { $0.categories.contains("selection") }
        )
        let context = makeContext(for: fixture)
        let evaluator = SuggestionEligibilityEvaluator()
        let now = Date(timeIntervalSinceReferenceDate: 10)
        let compatibilityDecision = supportedCompatibilityDecision(for: context)

        let automatic = evaluator.evaluate(
            context: context,
            previousContext: nil,
            compatibilityDecision: compatibilityDecision,
            lastSuggestionTriggerKeyAt: now,
            invocation: .automatic,
            now: now
        )
        let manual = evaluator.evaluate(
            context: context,
            previousContext: nil,
            compatibilityDecision: compatibilityDecision,
            lastSuggestionTriggerKeyAt: .distantPast,
            invocation: .manual,
            now: now
        )

        XCTAssertEqual(automatic.outcome, .ineligible(.selectionActive))
        XCTAssertTrue(manual.isEligible)

        let request = makeRequest(for: context)
        let normalized = SuggestionTextNormalizer.normalize(
            rawText: fixture.rawText,
            request: request
        )
        XCTAssertEqual(request.mode, .fillInMiddle)
        XCTAssertEqual(request.truncatedSelectedText, fixture.selectedText)
        XCTAssertEqual(normalized, fixture.expectedText)
    }

    func testUnicodeFixturesPreserveGraphemeClusters() throws {
        let fixtures = try loadFixtures().filter { $0.categories.contains("graphemeCluster") }
        XCTAssertGreaterThanOrEqual(fixtures.count, 2)

        for fixture in fixtures {
            let normalized = SuggestionTextNormalizer.normalize(
                rawText: fixture.rawText,
                request: makeRequest(for: fixture)
            )

            XCTAssertEqual(Array(normalized), Array(fixture.expectedText), fixture.name)
            XCTAssertEqual(
                normalized.unicodeScalars.map(\.value),
                fixture.expectedText.unicodeScalars.map(\.value),
                fixture.name
            )
        }
    }

    private func loadFixtures() throws -> [FIMNormalizerFixture] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures/FIMNormalizer/regressions.json")
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([FIMNormalizerFixture].self, from: data)
    }

    private func makeRequest(for fixture: FIMNormalizerFixture) -> CompletionRequest {
        makeRequest(for: makeContext(for: fixture))
    }

    private func makeRequest(for context: TextContext) -> CompletionRequest {
        CompletionRequestFactory().makeRequest(
            for: context,
            configuration: RemoteCompletionConfiguration(
                baseURL: "http://127.0.0.1:8000",
                apiKey: "test",
                model: "default"
            )
        )
    }

    private func makeContext(for fixture: FIMNormalizerFixture) -> TextContext {
        makeContext(
            textBeforeCursor: fixture.textBeforeCursor,
            textAfterCursor: fixture.textAfterCursor,
            selectedText: fixture.selectedText,
            fullTextWindow: fixture.fullTextWindow
        )
    }

    private func makeContext(
        textBeforeCursor: String,
        textAfterCursor: String?,
        selectedText: String? = nil,
        fullTextWindow: String? = nil
    ) -> TextContext {
        let resolvedFullTextWindow = fullTextWindow
            ?? "\(textBeforeCursor)\(selectedText ?? "")\(textAfterCursor ?? "")"
        let selectedRange = selectedText.map { selected in
            NSRange(location: textBeforeCursor.count, length: selected.count)
        }

        return TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            domain: "example.com",
            focusedElementID: "field",
            textBeforeCursor: textBeforeCursor,
            textAfterCursor: textAfterCursor,
            selectedText: selectedText,
            fullTextWindow: resolvedFullTextWindow,
            selectedRange: selectedRange
        )
    }

    private func supportedCompatibilityDecision(for context: TextContext) -> CompatibilityDecision {
        let profile = AppCompatibilityProfile(
            bundleID: context.app.bundleID,
            displayName: context.app.displayName,
            status: .works,
            defaultMode: .inline
        )
        return CompatibilityDecision(profile: profile, mode: .inline, enabled: true)
    }

    private func assertInsertable(
        _ normalized: String,
        request: CompletionRequest,
        fixtureName: String
    ) {
        XCTAssertFalse(normalized.isEmpty, fixtureName)
        XCTAssertFalse(normalized.contains(request.prompt), fixtureName)

        if let suffix = request.truncatedTextAfterCursor, !suffix.isEmpty {
            XCTAssertFalse(normalized.hasPrefix(suffix), fixtureName)
            XCTAssertNotEqual(normalized, suffix, fixtureName)
        }

        for forbidden in [
            "<|fim_prefix|>",
            "<|fim_suffix|>",
            "<|fim_middle|>",
            "<|assistant|>",
            "<completion>",
            "</completion>"
        ] {
            XCTAssertFalse(normalized.contains(forbidden), "\(fixtureName) leaked \(forbidden)")
        }
    }
}

private struct FIMNormalizerFixture: Decodable {
    let name: String
    let source: String
    let categories: [String]
    let textBeforeCursor: String
    let textAfterCursor: String?
    let selectedText: String?
    let fullTextWindow: String?
    let rawText: String
    let expectedText: String

    enum CodingKeys: String, CodingKey {
        case name
        case source
        case categories
        case textBeforeCursor
        case textAfterCursor
        case selectedText
        case fullTextWindow
        case rawText
        case expectedText
    }
}

private enum FuzzPattern: CaseIterable {
    case suffixEcho
    case prefixAndSuffixEcho
    case labeledSuffixEcho
    case fencedExplanation
    case xmlChatStop
    case suffixAtStart

    func rawText(prefix: String, insertion: String, suffix: String) -> String {
        switch self {
        case .suffixEcho:
            "\(insertion)\(suffix)"
        case .prefixAndSuffixEcho:
            "\(prefix)\(insertion)\(suffix)"
        case .labeledSuffixEcho:
            "Completion:\n\(insertion)\(suffix)"
        case .fencedExplanation:
            "Sure, here's the completion:\n```text\n\(insertion)\(suffix)\n```"
        case .xmlChatStop:
            "<|assistant|>\n<completion>\(insertion)</completion><|fim_suffix|>\(suffix)"
        case .suffixAtStart:
            "\(suffix)\(insertion)"
        }
    }
}

private struct SeededGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func nextIndex(upperBound: Int) -> Int {
        precondition(upperBound > 0)
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Int(state % UInt64(upperBound))
    }
}
