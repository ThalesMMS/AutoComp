import AutoCompCore
@testable import AutoCompApp
import XCTest

final class SuggestionOverlayStabilityGateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 100)

    func testOverlayHiddenPresents() {
        let gate = SuggestionOverlayStabilityGate()
        let decision = gate.decision(
            previous: nil,
            proposed: snapshot(),
            now: now,
            lastAcceptanceAt: nil
        )

        XCTAssertEqual(decision, .present(reason: .overlayHidden))
    }

    func testSubpointGeometryAndObservedCharacterWidthDriftSkips() {
        let gate = SuggestionOverlayStabilityGate()
        let previous = snapshot(
            context: context(
                focusedElementRect: CGRect(x: 50, y: 80, width: 400, height: 40),
                caretRect: CGRect(x: 100, y: 100, width: 2, height: 20),
                observedCharacterWidth: 7
            )
        )
        let proposed = snapshot(
            context: context(
                focusedElementRect: CGRect(x: 50.4, y: 80.3, width: 400.5, height: 40.2),
                caretRect: CGRect(x: 100.5, y: 99.6, width: 2, height: 20.4),
                observedCharacterWidth: 9
            )
        )

        let decision = gate.decision(
            previous: previous,
            proposed: proposed,
            now: now,
            lastAcceptanceAt: nil
        )

        XCTAssertEqual(decision, .skip(reason: .stableGeometry))
    }

    func testTextFocusFrameModeAndTierChangesPresent() {
        let gate = SuggestionOverlayStabilityGate()
        let previous = snapshot()

        XCTAssertEqual(
            gate.decision(
                previous: previous,
                proposed: snapshot(suggestion: suggestion(visibleText: " changed")),
                now: now,
                lastAcceptanceAt: nil
            ),
            .present(reason: .visibleTextChanged)
        )

        XCTAssertEqual(
            gate.decision(
                previous: previous,
                proposed: snapshot(context: context(focusChangeSequence: 2)),
                now: now,
                lastAcceptanceAt: nil
            ),
            .present(reason: .focusChanged)
        )

        XCTAssertEqual(
            gate.decision(
                previous: previous,
                proposed: snapshot(
                    context: context(focusedElementRect: CGRect(x: 70, y: 80, width: 400, height: 40))
                ),
                now: now,
                lastAcceptanceAt: nil
            ),
            .present(reason: .fieldFrameChanged)
        )

        XCTAssertEqual(
            gate.decision(
                previous: previous,
                proposed: snapshot(displayMode: .mirrorWindow),
                now: now,
                lastAcceptanceAt: nil
            ),
            .present(reason: .displayModeChanged)
        )

        XCTAssertEqual(
            gate.decision(
                previous: previous,
                proposed: snapshot(presentationTier: .mirrorWindow),
                now: now,
                lastAcceptanceAt: nil
            ),
            .present(reason: .presentationTierChanged)
        )
    }

    func testPostAcceptanceCaretDriftSkipsOnlyInsideWindow() {
        let gate = SuggestionOverlayStabilityGate(
            configuration: SuggestionOverlayStabilityGate.Configuration(
                postAcceptanceReconciliationWindow: 0.45
            )
        )
        let previous = snapshot(
            suggestion: suggestion(visibleText: "remaining", acceptedPrefix: "accepted "),
            context: context(caretRect: CGRect(x: 100, y: 100, width: 2, height: 20))
        )
        let proposed = snapshot(
            suggestion: suggestion(visibleText: "remaining", acceptedPrefix: "accepted "),
            context: context(caretRect: CGRect(x: 140, y: 100, width: 2, height: 20))
        )

        XCTAssertEqual(
            gate.decision(
                previous: previous,
                proposed: proposed,
                now: now.addingTimeInterval(0.2),
                lastAcceptanceAt: now
            ),
            .skip(reason: .postAcceptanceCaretDrift)
        )

        XCTAssertEqual(
            gate.decision(
                previous: previous,
                proposed: proposed,
                now: now.addingTimeInterval(0.6),
                lastAcceptanceAt: now
            ),
            .present(reason: .caretChanged)
        )
    }

    func testFieldFrameChangeStillPresentsDuringPostAcceptanceWindow() {
        let gate = SuggestionOverlayStabilityGate()
        let previous = snapshot(
            suggestion: suggestion(visibleText: "remaining", acceptedPrefix: "accepted "),
            context: context(focusedElementRect: CGRect(x: 50, y: 80, width: 400, height: 40))
        )
        let proposed = snapshot(
            suggestion: suggestion(visibleText: "remaining", acceptedPrefix: "accepted "),
            context: context(focusedElementRect: CGRect(x: 80, y: 80, width: 400, height: 40))
        )

        let decision = gate.decision(
            previous: previous,
            proposed: proposed,
            now: now.addingTimeInterval(0.1),
            lastAcceptanceAt: now
        )

        XCTAssertEqual(decision, .present(reason: .fieldFrameChanged))
    }

    private func snapshot(
        suggestion: Suggestion? = nil,
        context: TextContext? = nil,
        displayMode: SuggestionDisplayMode = .inline,
        presentationTier: PreviewPresentationTier = .visualInlineOverlay
    ) -> SuggestionOverlayStabilityGate.Snapshot {
        SuggestionOverlayStabilityGate.Snapshot(
            suggestion: suggestion ?? self.suggestion(),
            context: context ?? self.context(),
            displayMode: displayMode,
            presentationTier: presentationTier
        )
    }

    private func suggestion(
        visibleText: String = " continuation",
        acceptedPrefix: String = ""
    ) -> Suggestion {
        Suggestion(
            baseContextID: UUID(),
            visibleText: visibleText,
            acceptedPrefix: acceptedPrefix,
            latencyMs: 12
        )
    }

    private func context(
        focusedElementID: String = "field",
        focusedElementRect: CGRect? = CGRect(x: 50, y: 80, width: 400, height: 40),
        caretRect: CGRect? = CGRect(x: 100, y: 100, width: 2, height: 20),
        focusChangeSequence: UInt64? = 1,
        observedCharacterWidth: CGFloat? = nil
    ) -> TextContext {
        let app = AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 1)
        return TextContext(
            app: app,
            focusedElementID: focusedElementID,
            stableFieldIdentity: StableFieldIdentity(
                app: app,
                focusChangeSequence: focusChangeSequence
            ),
            textBeforeCursor: "Hello",
            selectedRange: NSRange(location: 5, length: 0),
            caretRect: caretRect,
            focusedElementRect: focusedElementRect,
            observedCharacterWidth: observedCharacterWidth
        )
    }
}
