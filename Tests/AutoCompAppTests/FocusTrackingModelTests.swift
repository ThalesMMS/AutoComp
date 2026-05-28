import ApplicationServices
import AutoCompCore
import CoreGraphics
@testable import AutoCompApp
import XCTest

@MainActor
final class FocusTrackingModelTests: XCTestCase {
    func testPublishesSnapshotAndIncrementsSequenceOnlyForRealFocusChange() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        let resolver = StubFocusSnapshotResolver(
            results: [
                .success(focusSnapshot(app: app, focusedElementID: "field-a", textBeforeCursor: "Please ")),
                .success(focusSnapshot(app: app, focusedElementID: "field-a", textBeforeCursor: "Please c")),
                .success(focusSnapshot(app: app, focusedElementID: "field-b", textBeforeCursor: "Other "))
            ]
        )
        let geometryResolver = StubGeometryResolver(geometries: [
            "field-a": geometry(
                focusedElementRect: CGRect(x: 100, y: 100, width: 500, height: 40),
                caretRect: CGRect(x: 180, y: 110, width: 1, height: 18),
                quality: .directCaret
            ),
            "field-b": geometry(
                focusedElementRect: CGRect(x: 100, y: 260, width: 500, height: 40),
                caretRect: CGRect(x: 180, y: 270, width: 1, height: 18),
                quality: .directCaret
            )
        ])
        let model = FocusTrackingModel(
            focusSnapshotResolver: resolver,
            textGeometryResolver: geometryResolver
        )

        let firstContext = try await model.currentContext()
        XCTAssertEqual(model.focusChangeSequence, 1)
        XCTAssertEqual(model.snapshot?.context, firstContext)
        XCTAssertEqual(model.capability, .readableText)
        XCTAssertNil(model.rejectionReason)

        _ = try await model.currentContext()
        XCTAssertEqual(model.focusChangeSequence, 1)

        _ = try await model.currentContext()
        XCTAssertEqual(model.focusChangeSequence, 2)
    }

    func testStableFieldIdentitySurvivesVolatileElementIDWhenFrameAppAndDomainMatch() async throws {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 42)
        let resolver = StubFocusSnapshotResolver(
            results: [
                .success(focusSnapshot(
                    app: app,
                    focusedElementID: "volatile-field-a",
                    domain: "example.com",
                    role: "AXTextArea",
                    subrole: "AXDocument",
                    textBeforeCursor: "Please "
                )),
                .success(focusSnapshot(
                    app: app,
                    focusedElementID: "volatile-field-b",
                    domain: "example.com",
                    role: "AXTextArea",
                    subrole: "AXDocument",
                    textBeforeCursor: "Please c"
                ))
            ]
        )
        let geometryResolver = StubGeometryResolver(geometries: [
            "volatile-field-a": geometry(
                focusedElementRect: CGRect(x: 100.2, y: 100.3, width: 500.2, height: 40.4),
                caretRect: CGRect(x: 180, y: 110, width: 1, height: 18),
                quality: .directCaret
            ),
            "volatile-field-b": geometry(
                focusedElementRect: CGRect(x: 100.4, y: 100.1, width: 500.3, height: 40.2),
                caretRect: CGRect(x: 188, y: 110, width: 1, height: 18),
                quality: .directCaret
            )
        ])
        let model = FocusTrackingModel(
            focusSnapshotResolver: resolver,
            textGeometryResolver: geometryResolver
        )

        let firstContext = try await model.currentContext()
        let secondContext = try await model.currentContext()

        XCTAssertEqual(firstContext.focusedElementID, "volatile-field-a")
        XCTAssertEqual(secondContext.focusedElementID, "volatile-field-b")
        XCTAssertEqual(model.focusChangeSequence, 1)
        XCTAssertEqual(model.snapshot?.stableFieldIdentity?.focusChangeSequence, 1)
        XCTAssertEqual(firstContext.stableFieldIdentity?.role, "AXTextArea")
        XCTAssertEqual(firstContext.stableFieldIdentity?.subrole, "AXDocument")
        XCTAssertEqual(firstContext.stableFieldIdentity?.roundedFocusedElementFrame, CGRect(x: 100, y: 100, width: 500, height: 40))
        XCTAssertTrue(
            try XCTUnwrap(firstContext.stableFieldIdentity)
                .matchesStableTarget(try XCTUnwrap(secondContext.stableFieldIdentity))
        )
    }

    func testUnreadableTextPublishesReadableRejection() async {
        let resolver = StubFocusSnapshotResolver(
            results: [
                .success(focusSnapshot(focusedElementID: "field-a", textBeforeCursor: nil))
            ]
        )
        let model = FocusTrackingModel(
            focusSnapshotResolver: resolver,
            textGeometryResolver: StubGeometryResolver()
        )

        do {
            _ = try await model.currentContext()
            XCTFail("Expected unreadable text to throw")
        } catch {
            XCTAssertEqual(model.capability, .unreadableText)
            XCTAssertEqual(model.rejectionReason, AXTextContextError.noReadableText.errorDescription)
            XCTAssertNil(model.snapshot)
        }
    }

    func testSecureFieldPublishesReadableRejection() async {
        let resolver = StubFocusSnapshotResolver(
            results: [
                .failure(AXTextContextError.secureOrUnsupportedField)
            ]
        )
        let model = FocusTrackingModel(
            focusSnapshotResolver: resolver,
            textGeometryResolver: StubGeometryResolver()
        )

        do {
            _ = try await model.currentContext()
            XCTFail("Expected secure field to throw")
        } catch {
            XCTAssertEqual(model.capability, .secureOrUnsupported)
            XCTAssertEqual(model.rejectionReason, AXTextContextError.secureOrUnsupportedField.errorDescription)
            XCTAssertNil(model.snapshot)
        }
    }

    func testWeakGeometryStillPublishesReadableSnapshot() async throws {
        let resolver = StubFocusSnapshotResolver(
            results: [
                .success(focusSnapshot(focusedElementID: "field-a", textBeforeCursor: "Please "))
            ]
        )
        let model = FocusTrackingModel(
            focusSnapshotResolver: resolver,
            textGeometryResolver: StubGeometryResolver(geometries: [
                "field-a": geometry(
                    focusedElementRect: CGRect(x: 100, y: 100, width: 500, height: 40),
                    caretRect: nil,
                    quality: .elementFrame
                )
            ])
        )

        let context = try await model.currentContext()

        XCTAssertEqual(context.caretGeometryQuality, .elementFrame)
        XCTAssertEqual(model.capability, .readableText)
        XCTAssertEqual(model.snapshot?.context, context)
        XCTAssertNil(model.rejectionReason)
    }

    func testScreenOCRGeometryFallbackOnlyReplacesGeometry() async throws {
        let fallbackResolver = StubScreenOCRGeometryFallbackResolver(
            fallback: ScreenOCRGeometryFallback(
                focusedElementRect: CGRect(x: 200, y: 220, width: 520, height: 44),
                caretRect: CGRect(x: 420, y: 230, width: 1, height: 18),
                previousGlyphRect: CGRect(x: 360, y: 230, width: 50, height: 18)
            )
        )
        let selectedRange = NSRange(location: 10, length: 0)
        let resolver = StubFocusSnapshotResolver(
            results: [
                .success(focusSnapshot(
                    focusedElementID: "field-a",
                    textBeforeCursor: "AX text ",
                    selectedRange: selectedRange,
                    textAfterCursor: "after",
                    fullTextWindow: "AX text after"
                ))
            ]
        )
        let model = FocusTrackingModel(
            focusSnapshotResolver: resolver,
            textGeometryResolver: StubGeometryResolver(
                geometries: [
                    "field-a": geometry(
                        focusedElementRect: CGRect(x: 100, y: 100, width: 500, height: 40),
                        caretRect: nil,
                        quality: .elementFrame
                    )
                ],
                useScreenOCRFallback: true
            ),
            screenOCRGeometryFallbackResolver: fallbackResolver
        )

        let context = try await model.currentContext()

        XCTAssertEqual(context.textBeforeCursor, "AX text ")
        XCTAssertEqual(context.textAfterCursor, "after")
        XCTAssertEqual(context.fullTextWindow, "AX text after")
        XCTAssertEqual(context.selectedRange, selectedRange)
        XCTAssertEqual(context.caretRect, CGRect(x: 420, y: 230, width: 1, height: 18))
        XCTAssertEqual(context.focusedElementRect, CGRect(x: 200, y: 220, width: 520, height: 44))
        XCTAssertEqual(context.previousGlyphRect, CGRect(x: 360, y: 230, width: 50, height: 18))
        XCTAssertEqual(context.caretGeometryQuality, .screenOCR)
        XCTAssertEqual(context.captureSources, [.accessibility, .screenOCR])
        XCTAssertEqual(fallbackResolver.authoritativeTexts, ["AX text "])
    }

    func testSafeOverlayModeSkipsScreenOCRGeometryFallback() async throws {
        let fallbackResolver = StubScreenOCRGeometryFallbackResolver(
            fallback: ScreenOCRGeometryFallback(
                focusedElementRect: CGRect(x: 200, y: 220, width: 520, height: 44),
                caretRect: CGRect(x: 420, y: 230, width: 1, height: 18),
                previousGlyphRect: CGRect(x: 360, y: 230, width: 50, height: 18)
            )
        )
        let resolver = StubFocusSnapshotResolver(
            results: [
                .success(focusSnapshot(focusedElementID: "field-a", textBeforeCursor: "AX text "))
            ]
        )
        let model = FocusTrackingModel(
            focusSnapshotResolver: resolver,
            textGeometryResolver: StubGeometryResolver(
                geometries: [
                    "field-a": geometry(
                        focusedElementRect: CGRect(x: 100, y: 100, width: 500, height: 40),
                        caretRect: nil,
                        quality: .elementFrame
                    )
                ],
                useScreenOCRFallback: true
            ),
            screenOCRGeometryFallbackResolver: fallbackResolver,
            safeOverlayModeEnabled: true
        )

        let context = try await model.currentContext()

        XCTAssertNil(context.caretRect)
        XCTAssertEqual(context.focusedElementRect, CGRect(x: 100, y: 100, width: 500, height: 40))
        XCTAssertEqual(context.caretGeometryQuality, .elementFrame)
        XCTAssertEqual(context.captureSources, [.accessibility])
        XCTAssertEqual(fallbackResolver.authoritativeTexts, [])
    }

    func testPublishesSuffixSelectionAndFullTextWindow() async throws {
        let resolver = StubFocusSnapshotResolver(
            results: [
                .success(focusSnapshot(
                    focusedElementID: "field-a",
                    textBeforeCursor: "A reuniao foi ",
                    selectedRange: NSRange(location: 14, length: 6),
                    textAfterCursor: " porque o prazo mudou.",
                    selectedText: "adiada",
                    fullTextWindow: "A reuniao foi adiada porque o prazo mudou."
                ))
            ]
        )
        let model = FocusTrackingModel(
            focusSnapshotResolver: resolver,
            textGeometryResolver: StubGeometryResolver()
        )

        let context = try await model.currentContext()

        XCTAssertEqual(context.textAfterCursor, " porque o prazo mudou.")
        XCTAssertEqual(context.selectedText, "adiada")
        XCTAssertEqual(context.fullTextWindow, "A reuniao foi adiada porque o prazo mudou.")
    }

    func testFocusSnapshotTextWindowLimitsAroundSelection() {
        let fullText = "0123456789abcdefghij"
        let window = FocusSnapshotTextWindow.resolve(
            textAfterCursor: "abcdefghij",
            selectedText: "56789",
            fullText: fullText,
            selectedRange: NSRange(location: 5, length: 5),
            maxTextAfterCursorCharacters: 4,
            maxSelectedTextCharacters: 3,
            maxFullTextWindowCharacters: 8
        )

        XCTAssertEqual(window.textAfterCursor, "abcd")
        XCTAssertEqual(window.selectedText, "567")
        XCTAssertEqual(window.fullTextWindow, "3456789a")
    }

    private func focusSnapshot(
        app: AppIdentity = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
        focusedElementID: String,
        domain: String? = nil,
        role: String? = "AXTextArea",
        subrole: String? = nil,
        textBeforeCursor: String?,
        selectedRange: NSRange? = NSRange(location: 7, length: 0),
        textAfterCursor: String? = nil,
        selectedText: String? = nil,
        fullTextWindow: String? = nil
    ) -> AXFocusSnapshot {
        AXFocusSnapshot(
            app: app,
            bundleID: app.bundleID,
            displayName: app.displayName,
            focusedElement: AXUIElementCreateSystemWide(),
            focusedElementID: focusedElementID,
            domain: domain,
            domainResolution: .inferred(domain: domain),
            role: role,
            subrole: subrole,
            isGoogleDocsElement: false,
            isCodexComposerElement: false,
            selectedRange: selectedRange,
            fullText: textBeforeCursor,
            textLength: textBeforeCursor.map { ($0 as NSString).length } ?? 0,
            textBeforeCursor: textBeforeCursor,
            textAfterCursor: textAfterCursor,
            selectedText: selectedText,
            fullTextWindow: fullTextWindow
        )
    }

    private func geometry(
        focusedElementRect: CGRect?,
        caretRect: CGRect?,
        quality: CaretGeometryQuality
    ) -> AXTextGeometrySnapshot {
        AXTextGeometrySnapshot(
            focusedElementRect: focusedElementRect,
            caretRect: caretRect,
            previousGlyphRect: nil,
            nextGlyphRect: nil,
            lineReferenceRect: nil,
            caretGeometryQuality: quality,
            observedCharacterWidth: nil
        )
    }
}

private final class StubFocusSnapshotResolver: FocusSnapshotResolving {
    private var results: [Result<AXFocusSnapshot, Error>]

    init(results: [Result<AXFocusSnapshot, Error>]) {
        self.results = results
    }

    func resolve() throws -> AXFocusSnapshot {
        guard !results.isEmpty else {
            throw AXTextContextError.noFocusedElement
        }
        switch results.removeFirst() {
        case .success(let snapshot):
            return snapshot
        case .failure(let error):
            throw error
        }
    }
}

private struct StubGeometryResolver: AXTextGeometryResolving {
    var geometries: [String: AXTextGeometrySnapshot] = [:]
    var useScreenOCRFallback = false

    func resolve(snapshot: AXFocusSnapshot) -> AXTextGeometrySnapshot {
        geometries[snapshot.focusedElementID] ?? AXTextGeometrySnapshot(
            focusedElementRect: CGRect(x: 100, y: 100, width: 500, height: 40),
            caretRect: CGRect(x: 180, y: 110, width: 1, height: 18),
            previousGlyphRect: nil,
            nextGlyphRect: nil,
            lineReferenceRect: nil,
            caretGeometryQuality: .directCaret,
            observedCharacterWidth: nil
        )
    }

    func shouldUseScreenOCRFallback(
        snapshot: AXFocusSnapshot,
        geometry: AXTextGeometrySnapshot
    ) -> Bool {
        useScreenOCRFallback
    }
}

private final class StubScreenOCRGeometryFallbackResolver: ScreenOCRGeometryFallbackResolving {
    private let fallback: ScreenOCRGeometryFallback?
    private(set) var authoritativeTexts: [String] = []

    init(fallback: ScreenOCRGeometryFallback?) {
        self.fallback = fallback
    }

    func resolve(searchRect: CGRect?, authoritativeText: String) async -> ScreenOCRGeometryFallback? {
        authoritativeTexts.append(authoritativeText)
        return fallback
    }
}
