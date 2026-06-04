import AppKit
@testable import AutoCompApp
import AutoCompCore
import XCTest

@MainActor
final class OverlayPresenterSupportTests: XCTestCase {
    func testAnchorRectUsesCaretPreviousNextLineFocusedPriority() {
        let context = TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: "Hello",
            caretRect: CGRect(x: 10, y: 10, width: 2, height: 20),
            focusedElementRect: CGRect(x: 50, y: 50, width: 200, height: 40),
            previousGlyphRect: CGRect(x: 8, y: 10, width: 8, height: 20),
            nextGlyphRect: CGRect(x: 12, y: 10, width: 8, height: 20),
            lineReferenceRect: CGRect(x: 10, y: 30, width: 200, height: 20)
        )

        XCTAssertEqual(OverlayPresenterGeometry.anchorRect(for: context), context.caretRect)
        XCTAssertEqual(
            OverlayPresenterGeometry.anchorRect(for: context.without(caret: true)),
            context.previousGlyphRect
        )
        XCTAssertEqual(
            OverlayPresenterGeometry.anchorRect(for: context.without(caret: true, previousGlyph: true)),
            context.nextGlyphRect
        )
        XCTAssertEqual(
            OverlayPresenterGeometry.anchorRect(for: context.without(caret: true, previousGlyph: true, nextGlyph: true)),
            context.lineReferenceRect
        )
        XCTAssertEqual(
            OverlayPresenterGeometry.anchorRect(for: context.without(caret: true, previousGlyph: true, nextGlyph: true, line: true)),
            context.focusedElementRect
        )
    }

    func testAnchorRectReturnsNilWithoutAnyGeometry() {
        let context = TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: "Hello"
        )

        XCTAssertNil(OverlayPresenterGeometry.anchorRect(for: context))
    }

    func testOverlayPresentersUseSharedPanelHintsAndAnchorSupport() throws {
        let root = try packageRoot()
        let presenterSource = try String(
            contentsOf: root.appendingPathComponent("Sources/AutoCompApp/Services/Overlay/Presenters/OverlaySuggestionPresenters.swift"),
            encoding: .utf8
        )
        let supportSource = try String(
            contentsOf: root.appendingPathComponent("Sources/AutoCompApp/Services/Overlay/Presenters/OverlayPresenterSupport.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(supportSource.contains("struct OverlayPresenterGeometry"))
        XCTAssertTrue(supportSource.contains("final class OverlayPanelHost"))
        XCTAssertTrue(supportSource.contains("struct OverlayShortcutHintResolver"))
        XCTAssertTrue(supportSource.contains("enum OverlayPresenterLog"))
        XCTAssertTrue(presenterSource.contains("OverlayPresenterGeometry.screenContext"))
        XCTAssertTrue(presenterSource.contains("OverlayPanelHost<"))
        XCTAssertTrue(presenterSource.contains("shortcutHintResolver.hints()"))
        XCTAssertTrue(presenterSource.contains("OverlayPresenterLog.rejected"))
        XCTAssertFalse(presenterSource.contains("private var panel: NSPanel?"))
        XCTAssertFalse(presenterSource.contains("private var contentView:"))
        XCTAssertFalse(presenterSource.contains("shortcutSettingsStore.load()"))
        XCTAssertFalse(presenterSource.contains("NSScreen.screens.map(\\.frame)"))
    }

    private func packageRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url.deleteLastPathComponent()
        }

        throw XCTSkip("Unable to locate package root")
    }
}

private extension TextContext {
    func without(
        caret: Bool = false,
        previousGlyph: Bool = false,
        nextGlyph: Bool = false,
        line: Bool = false
    ) -> TextContext {
        TextContext(
            app: app,
            domain: domain,
            focusedElementID: focusedElementID,
            textBeforeCursor: textBeforeCursor,
            textAfterCursor: textAfterCursor,
            fullTextWindow: fullTextWindow,
            selectedRange: selectedRange,
            caretRect: caret ? nil : caretRect,
            focusedElementRect: focusedElementRect,
            previousGlyphRect: previousGlyph ? nil : previousGlyphRect,
            nextGlyphRect: nextGlyph ? nil : nextGlyphRect,
            lineReferenceRect: line ? nil : lineReferenceRect,
            caretGeometryQuality: caretGeometryQuality,
            observedCharacterWidth: observedCharacterWidth,
            captureSources: captureSources
        )
    }
}
