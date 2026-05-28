import AppKit
import AutoCompCore
@testable import AutoCompApp
import XCTest

@MainActor
final class OverlayGeometryCorpusTests: XCTestCase {
    func testCorpusContainsNamedAccessibilityGeometryFixtures() {
        let expectedIDs = Set([
            "zero-rect",
            "upper-left-fallback-rect",
            "outside-all-screens",
            "retina-physical-pixel-rect",
            "wide-caret-normalization",
            "caret-far-from-focused-element",
            "focused-element-too-small",
            "multi-monitor-negative-origin",
            "browser-line-metric-quirk",
            "ocr-fallback-rect"
        ])
        let fixtures = OverlayGeometryCorpus.fixtures

        XCTAssertEqual(Set(fixtures.map(\.id)), expectedIDs)
        for fixture in fixtures {
            XCTAssertFalse(fixture.scenario.isEmpty, fixture.id)
            XCTAssertNotNil(OverlayGeometryAppClass(rawValue: fixture.appClass.rawValue), fixture.id)
            XCTAssertFalse(fixture.expected.reason.isEmpty, fixture.id)
            XCTAssertNotNil(fixture.selectedRange, fixture.id)
            XCTAssertFalse(fixture.captureSources.isEmpty, fixture.id)
            XCTAssertTrue(fixture.screenFrame.width > 0, fixture.id)
            XCTAssertTrue(hasAnyInputRect(fixture.inputRects), fixture.id)
        }
    }

    func testCorpusPassesValidatorInlinePreviewAndCoordinatorPaths() {
        for fixture in OverlayGeometryCorpus.fixtures {
            let context = fixture.makeContext()
            let tier = resolvedTier(for: fixture, context: context)
            let result = OverlayGeometryCorpus.run(fixture: fixture, tier: tier)

            XCTAssertEqual(result.tier, fixture.expected.tier, fixture.id)
            XCTAssertEqual(result.validation.focusedElementRect, fixture.expected.validation.focusedElementRect, fixture.id)
            XCTAssertEqual(result.validation.caretRect, fixture.expected.validation.caretRect, fixture.id)
            XCTAssertEqual(result.validation.previousGlyphRect, fixture.expected.validation.previousGlyphRect, fixture.id)
            XCTAssertEqual(result.validation.nextGlyphRect, fixture.expected.validation.nextGlyphRect, fixture.id)
            XCTAssertEqual(result.validation.lineReferenceRect, fixture.expected.validation.lineReferenceRect, fixture.id)
            XCTAssertEqual(result.inlineSource, fixture.expected.inlineSource, fixture.id)
            XCTAssertEqual(result.inlineRejectionReason, fixture.expected.inlineRejectionReason, fixture.id)
        }
    }

    func testCorpusRedactedLogsDoNotContainCapturedTextOrRectPayloads() {
        for fixture in OverlayGeometryCorpus.fixtures {
            let context = fixture.makeContext()
            let result = OverlayGeometryCorpus.run(
                fixture: fixture,
                tier: resolvedTier(for: fixture, context: context)
            )
            let logLine = result.redactedLogLine

            XCTAssertFalse(logLine.contains(fixture.textBeforeCursor), fixture.id)
            XCTAssertFalse(logLine.contains(context.textBeforeCursor), fixture.id)
            XCTAssertFalse(logLine.contains("synthetic corpus prefix"), fixture.id)
            XCTAssertFalse(logLine.contains("CGRect"), fixture.id)
            XCTAssertFalse(logLine.contains("visibleText"), fixture.id)
            XCTAssertTrue(logLine.contains("fixture=\(fixture.id)"), fixture.id)
            XCTAssertTrue(logLine.contains("appClass=\(fixture.appClass.rawValue)"), fixture.id)
            XCTAssertTrue(logLine.contains("reason=\(fixture.expected.reason)"), fixture.id)
        }
    }

    private func resolvedTier(
        for fixture: OverlayGeometryCorpusFixture,
        context: TextContext
    ) -> PreviewPresentationTier {
        let coordinator = PreviewCoordinator(
            nativeInlinePresenter: CorpusUnavailableNativePresenter(),
            visualInlinePresenter: CorpusVisualInlinePresenter(fixture: fixture),
            mirrorWindowPresenter: CorpusMirrorPresenter(),
            simpleCaretPopupPresenter: CorpusSimpleCaretPresenter(fixture: fixture),
            safeOverlayModeEnabled: false
        )
        return coordinator.resolveTier(
            for: suggestion(for: fixture),
            context: context,
            mode: .inline
        )
    }

    private func suggestion(for fixture: OverlayGeometryCorpusFixture) -> Suggestion {
        Suggestion(
            baseContextID: UUID(),
            visibleText: " continuation",
            latencyMs: 12
        )
    }

    private func hasAnyInputRect(_ inputRects: OverlayGeometryInputRects) -> Bool {
        inputRects.caretRect != nil
            || inputRects.focusedElementRect != nil
            || inputRects.previousGlyphRect != nil
            || inputRects.nextGlyphRect != nil
            || inputRects.lineReferenceRect != nil
    }
}

@MainActor
private final class CorpusUnavailableNativePresenter: NativeInlineSuggestionPresenting {
    func canPresent(_ suggestion: Suggestion, for context: TextContext) -> Bool {
        false
    }

    func show(_ suggestion: Suggestion, for context: TextContext) {}
    func update(_ suggestion: Suggestion, for context: TextContext) {}
    func hide() {}
}

@MainActor
private final class CorpusVisualInlinePresenter: VisualInlineSuggestionPresenting {
    private let fixture: OverlayGeometryCorpusFixture

    init(fixture: OverlayGeometryCorpusFixture) {
        self.fixture = fixture
    }

    func canPresent(_ suggestion: Suggestion, for context: TextContext) -> Bool {
        InlinePreviewGeometry.layout(
            context: context,
            contentSize: fixture.contentSize,
            screenFrame: fixture.screenFrame,
            visibleFrame: fixture.visibleFrame,
            screenFrames: fixture.screenFrames,
            allowsLineWrapPlacement: true
        ) != nil
    }

    func show(_ suggestion: Suggestion, for context: TextContext) {}
    func update(_ suggestion: Suggestion, for context: TextContext) {}
    func hide() {}
}

@MainActor
private final class CorpusSimpleCaretPresenter: VisualInlineSuggestionPresenting {
    private let fixture: OverlayGeometryCorpusFixture

    init(fixture: OverlayGeometryCorpusFixture) {
        self.fixture = fixture
    }

    func canPresent(_ suggestion: Suggestion, for context: TextContext) -> Bool {
        SimpleCaretPopupLayout.resolve(
            text: suggestion.visibleText,
            context: context,
            font: NSFont.systemFont(ofSize: 14),
            screenFrame: fixture.screenFrame,
            visibleFrame: fixture.visibleFrame,
            screenFrames: fixture.screenFrames
        ) != nil
    }

    func show(_ suggestion: Suggestion, for context: TextContext) {}
    func update(_ suggestion: Suggestion, for context: TextContext) {}
    func hide() {}
}

@MainActor
private final class CorpusMirrorPresenter: SuggestionTierPresenting {
    func show(_ suggestion: Suggestion, for context: TextContext) {}
    func update(_ suggestion: Suggestion, for context: TextContext) {}
    func hide() {}
}
