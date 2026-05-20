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

    private func focusSnapshot(
        app: AppIdentity = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
        focusedElementID: String,
        textBeforeCursor: String?,
        selectedRange: NSRange? = NSRange(location: 7, length: 0)
    ) -> AXFocusSnapshot {
        AXFocusSnapshot(
            app: app,
            bundleID: app.bundleID,
            displayName: app.displayName,
            focusedElement: AXUIElementCreateSystemWide(),
            focusedElementID: focusedElementID,
            domain: nil,
            isGoogleDocsElement: false,
            isCodexComposerElement: false,
            selectedRange: selectedRange,
            fullText: textBeforeCursor,
            textLength: textBeforeCursor.map { ($0 as NSString).length } ?? 0,
            textBeforeCursor: textBeforeCursor
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
        false
    }
}
