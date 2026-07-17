import AutoCompCore
import CoreGraphics
import XCTest

final class CaretGeometryAuthorityPolicyTests: XCTestCase {
    private let policy = CaretGeometryAuthorityPolicy(webBridgeVerticalReplacementThreshold: 12)

    func testNativeAndMeasuredRunGeometryCannotBeReplacedByLayoutEstimate() {
        for provenance in [
            CaretGeometryProvenance.nativeSelectedRange,
            .nativeCharacterBounds,
            .measuredTextRun
        ] {
            XCTAssertEqual(
                policy.decision(
                    existingQuality: .directCaret,
                    existingProvenance: provenance,
                    candidateProvenance: .hiddenTextLayoutEstimate,
                    hostBundleID: "com.google.Chrome",
                    verticalDelta: 80,
                    hasIndependentEvidence: true
                ),
                .keepExisting
            )
        }
    }

    func testWeakElementFrameCanUseValidatedLayoutEstimateAndPendingInsertion() {
        XCTAssertEqual(
            policy.decision(
                existingQuality: .elementFrame,
                existingProvenance: .focusedElementFrame,
                candidateProvenance: .hiddenTextLayoutEstimate,
                hostBundleID: "com.openai.codex",
                pendingInsertion: "accepted text\n"
            ),
            .useCandidate
        )
    }

    func testWebBridgeRequiresMaterialVerticalDeltaAndIndependentEvidence() {
        XCTAssertEqual(
            policy.decision(
                existingQuality: .lineMetric,
                existingProvenance: .webAccessibilityBridge,
                candidateProvenance: .hiddenTextLayoutEstimate,
                hostBundleID: "com.google.Chrome",
                verticalDelta: 8,
                hasIndependentEvidence: true
            ),
            .keepExisting
        )
        XCTAssertEqual(
            policy.decision(
                existingQuality: .lineMetric,
                existingProvenance: .webAccessibilityBridge,
                candidateProvenance: .hiddenTextLayoutEstimate,
                hostBundleID: "com.google.Chrome",
                verticalDelta: 24,
                hasIndependentEvidence: true
            ),
            .useCandidate
        )
    }

    func testOCRIsNeverSilentlyPromotedToNativeAuthority() {
        XCTAssertEqual(
            policy.decision(
                existingQuality: .screenOCR,
                existingProvenance: .screenOCR,
                candidateProvenance: .hiddenTextLayoutEstimate,
                hostBundleID: "com.google.Chrome"
            ),
            .candidateForDiagnosticsOnly
        )
    }

    func testWeakProducerForcesPopupEvenWhenQualityLooksInlineCapable() {
        XCTAssertEqual(
            CaretGeometryTrustEvaluator.default.evaluate(
                caretRect: CGRect(x: 100, y: 100, width: 1, height: 18),
                focusedElementRect: CGRect(x: 80, y: 80, width: 400, height: 80),
                screenBounds: CGRect(x: 0, y: 0, width: 1_000, height: 1_000),
                quality: .lineMetric,
                provenance: .hiddenTextLayoutEstimate
            ),
            .forcePopup
        )
    }

    func testOlderTextContextPayloadDecodesWithoutNewGeometryMetadata() throws {
        let context = TextContext(
            app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1),
            focusedElementID: "field",
            textBeforeCursor: "hello",
            caretRect: CGRect(x: 10, y: 20, width: 1, height: 18),
            caretGeometryQuality: .directCaret,
            caretGeometryProvenance: .nativeSelectedRange,
            caretGeometryCoordinateSpace: .accessibilityGlobal
        )
        let encoded = try JSONEncoder().encode(context)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "caretGeometryProvenance")
        object.removeValue(forKey: "caretGeometryCoordinateSpace")
        let legacy = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(TextContext.self, from: legacy)

        XCTAssertNil(decoded.caretGeometryProvenance)
        XCTAssertNil(decoded.caretGeometryCoordinateSpace)
        XCTAssertEqual(decoded.caretGeometryQuality, .directCaret)
    }
}
