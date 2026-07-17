import ApplicationServices
import AutoCompCore
import CoreGraphics
@testable import AutoCompApp
import XCTest

@MainActor
final class FocusTrackingModelTests: XCTestCase {
    func testSuspendedPipelineDoesNotResolveAXContext() async throws {
        let suspensionController = InteractionPipelineSuspensionController()
        let token = suspensionController.suspend(reason: .openPanel)
        let resolver = StubFocusSnapshotResolver(
            results: [
                .success(focusSnapshot(focusedElementID: "field-a", textBeforeCursor: "Please "))
            ]
        )
        let model = FocusTrackingModel(
            focusSnapshotResolver: resolver,
            textGeometryResolver: StubGeometryResolver(),
            interactionPipelineSuspensionController: suspensionController
        )

        do {
            _ = try await model.currentContext()
            XCTFail("Expected suspended pipeline to throw")
        } catch {
            XCTAssertEqual(error as? AXTextContextError, .interactionPipelineSuspended)
            XCTAssertEqual(model.capability, .unavailable)
            XCTAssertEqual(model.rejectionReason, AXTextContextError.interactionPipelineSuspended.errorDescription)
        }

        suspensionController.resume(token)
        let context = try await model.currentContext()
        XCTAssertEqual(context.textBeforeCursor, "Please ")
    }

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

    func testTransientUnreadableCapabilityIsSuppressedOnceThenApplied() async throws {
        let resolver = StubFocusSnapshotResolver(results: [
            .success(focusSnapshot(focusedElementID: "field-a", textBeforeCursor: "Please ")),
            .success(focusSnapshot(focusedElementID: "field-a", textBeforeCursor: nil)),
            .success(focusSnapshot(focusedElementID: "field-a", textBeforeCursor: nil))
        ])
        let model = FocusTrackingModel(
            focusSnapshotResolver: resolver,
            textGeometryResolver: StubGeometryResolver()
        )

        let readable = try await model.currentContext()
        let preserved = try await model.currentContext()

        XCTAssertEqual(preserved, readable)
        XCTAssertEqual(model.capability, .readableText)
        XCTAssertEqual(model.capabilityFlickerStats.suppressedReads, 1)
        XCTAssertEqual(model.capabilityFlickerStats.lastReason, "same-field-transient-capability")

        do {
            _ = try await model.currentContext()
            XCTFail("Expected the second consecutive unreadable read to apply")
        } catch {
            XCTAssertEqual(error as? AXTextContextError, .noReadableText)
        }
        XCTAssertEqual(model.capability, .unreadableText)
        XCTAssertNil(model.snapshot)
        XCTAssertEqual(model.capabilityFlickerStats.appliedReads, 1)
        XCTAssertEqual(model.capabilityFlickerStats.lastReason, "consecutive-transient-threshold")
    }

    func testCapabilityFlickerGateNeverDelaysSecureOrFocusChange() {
        var gate = FocusCapabilityFlickerGate()

        XCTAssertEqual(
            gate.evaluate(capability: .secureOrUnsupported, sameStableField: true),
            .apply(reason: "secure-or-unsupported-immediate")
        )
        XCTAssertEqual(
            gate.evaluate(capability: .unavailable, sameStableField: false),
            .apply(reason: "focus-identity-changed")
        )
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

    func testScreenOCRGeometryFallbackTimeoutKeepsReadableContext() async throws {
        let fallbackResolver = HangingScreenOCRGeometryFallbackResolver()
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
            screenOCRGeometryFallbackTimeout: 0.01
        )

        let context = try await model.currentContext()

        XCTAssertEqual(context.textBeforeCursor, "AX text ")
        XCTAssertNil(context.caretRect)
        XCTAssertEqual(context.focusedElementRect, CGRect(x: 100, y: 100, width: 500, height: 40))
        XCTAssertEqual(context.caretGeometryQuality, .elementFrame)
        XCTAssertEqual(context.captureSources, [.accessibility])
        let fallbackCallCount = await fallbackResolver.callCount()
        XCTAssertEqual(fallbackCallCount, 1)
        await fallbackResolver.resumeHangingResolutions()
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

    func testFocusSnapshotTextWindowNeverSplitsComposedCharacters() {
        let window = FocusSnapshotTextWindow.resolve(
            textAfterCursor: "😀abc",
            selectedText: "e\u{301}x",
            fullText: "A😀BCDEF",
            selectedRange: NSRange(location: 4, length: 0),
            maxTextAfterCursorCharacters: 1,
            maxSelectedTextCharacters: 1,
            maxFullTextWindowCharacters: 4
        )

        XCTAssertNil(window.textAfterCursor)
        XCTAssertNil(window.selectedText)
        XCTAssertEqual(window.fullTextWindow, "BCD")
        XCTAssertFalse(window.fullTextWindow?.contains("�") == true)
        XCTAssertEqual(UTF16TextRange.prefix("A😀B", endingAt: 2), "A")
        XCTAssertEqual(UTF16TextRange.suffix("A😀B", startingAt: 2), "B")
        XCTAssertEqual(
            UTF16TextRange.substring("A😀B", enclosedBy: NSRange(location: 1, length: 1)),
            ""
        )
    }

    func testFocusSnapshotTextCaptureUsesRangedReadsWithoutLoadingFullValue() {
        let source = "0123456789ABCDEFGHIJ"
        var requestedRanges: [CFRange] = []
        var fullTextReadCount = 0

        let capture = FocusSnapshotTextCapture.resolve(
            selectedRange: NSRange(location: 10, length: 0),
            textLength: (source as NSString).length,
            readRange: { range in
                requestedRanges.append(range)
                return UTF16TextRange.substring(source, enclosedBy: NSRange(
                    location: range.location,
                    length: range.length
                ))
            },
            readFullText: {
                fullTextReadCount += 1
                return source
            },
            maxTextAfterCursorCharacters: 4,
            maxSelectedTextCharacters: 4,
            maxFullTextWindowCharacters: 8
        )

        XCTAssertEqual(fullTextReadCount, 0)
        XCTAssertEqual(capture.textBeforeCursor, "0123456789")
        XCTAssertEqual(capture.textAfterCursor, "ABCD")
        XCTAssertNil(capture.selectedText)
        XCTAssertEqual(capture.fullTextWindow, "6789ABCD")
        XCTAssertTrue(requestedRanges.contains { $0.location == 0 && $0.length == 10 })
        XCTAssertTrue(requestedRanges.contains { $0.location == 10 && $0.length == 4 })
    }

    func testFocusSnapshotTextCaptureFallsBackOnceWhenRequiredRangeFails() {
        let source = "0123456789"
        var fullTextReadCount = 0

        let capture = FocusSnapshotTextCapture.resolve(
            selectedRange: NSRange(location: 5, length: 0),
            textLength: (source as NSString).length,
            readRange: { range in
                if range.location == 0, range.length == 5 {
                    return nil
                }
                return UTF16TextRange.substring(source, enclosedBy: NSRange(
                    location: range.location,
                    length: range.length
                ))
            },
            readFullText: {
                fullTextReadCount += 1
                return source
            }
        )

        XCTAssertEqual(fullTextReadCount, 1)
        XCTAssertEqual(capture.textBeforeCursor, "01234")
        XCTAssertEqual(capture.textAfterCursor, "56789")
        XCTAssertEqual(capture.textLength, 10)
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

private final class StubScreenOCRGeometryFallbackResolver: ScreenOCRGeometryFallbackResolving, @unchecked Sendable {
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

private actor HangingScreenOCRGeometryFallbackResolver: ScreenOCRGeometryFallbackResolving {
    private var storedCallCount = 0
    private var continuations: [CheckedContinuation<ScreenOCRGeometryFallback?, Never>] = []

    func callCount() -> Int {
        storedCallCount
    }

    func resolve(searchRect: CGRect?, authoritativeText: String) async -> ScreenOCRGeometryFallback? {
        storedCallCount += 1
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func resumeHangingResolutions() {
        let pendingContinuations = continuations
        continuations.removeAll()
        for continuation in pendingContinuations {
            continuation.resume(returning: nil)
        }
    }
}
