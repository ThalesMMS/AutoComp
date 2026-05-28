import AutoCompCore
@testable import AutoCompApp
import XCTest

final class MenuStatusSnapshotTests: XCTestCase {
    func testMissingPermissionsSurfaceActionableStatuses() throws {
        let snapshot = MenuStatusSnapshot.make(
            accessibilityTrusted: false,
            inputMonitoringAllowed: false,
            backendStatusSummary: .connected,
            inputMethod: .init(summary: "ASCII", inputSourceID: nil),
            focus: nil,
            focusFailure: nil,
            compatibilityDecision: nil,
            autocompleteEnabled: true
        )

        XCTAssertEqual(try item("accessibility", in: snapshot).value, "Missing")
        XCTAssertEqual(try item("input", in: snapshot).value, "Missing")
        XCTAssertEqual(try item("focus", in: snapshot).value, "Blocked")
        XCTAssertEqual(try item("lastDecision", in: snapshot).value, "Blocked")
        XCTAssertTrue(try item("lastDecision", in: snapshot).action.contains("missing-permission"))
        XCTAssertTrue(try item("accessibility", in: snapshot).action.contains("Accessibility"))
        XCTAssertTrue(try item("input", in: snapshot).action.contains("Input Monitoring"))
    }

    func testPausedBackendShowsCircuitBreakerStatusAndReason() throws {
        let now = Date(timeIntervalSince1970: 500)
        let snapshot = MenuStatusSnapshot.make(
            accessibilityTrusted: true,
            inputMonitoringAllowed: true,
            backendStatusSummary: BackendStatusSummary(
                state: .paused,
                issue: .timeout,
                suppressUntil: now.addingTimeInterval(30)
            ),
            inputMethod: .init(summary: "ASCII", inputSourceID: nil),
            focus: Self.focus(),
            focusFailure: nil,
            compatibilityDecision: Self.decision(),
            autocompleteEnabled: true,
            now: now
        )

        let backend = try item("backend", in: snapshot)
        XCTAssertEqual(backend.value, "Paused")
        XCTAssertTrue(backend.action.contains("Timeout"))
        XCTAssertTrue(backend.action.contains("30s"))
    }

    func testManualOnlyCompatibilityIsVisibleInModeRow() throws {
        let snapshot = MenuStatusSnapshot.make(
            accessibilityTrusted: true,
            inputMonitoringAllowed: true,
            backendStatusSummary: .connected,
            inputMethod: .init(summary: "ASCII", inputSourceID: nil),
            focus: Self.focus(),
            focusFailure: nil,
            compatibilityDecision: Self.decision(overrideMode: .manualOnly, allowsAutomaticSuggestions: false),
            autocompleteEnabled: true
        )

        XCTAssertEqual(try item("focus", in: snapshot).value, "Supported")
        XCTAssertEqual(try item("mode", in: snapshot).value, "Manual-only")
        XCTAssertTrue(try item("mode", in: snapshot).action.contains("manual trigger"))
    }

    func testDisabledCompatibilityBlocksFocusAndMode() throws {
        let decision = Self.decision(
            status: .unsupported,
            mode: .disabled,
            enabled: false,
            overrideMode: .disabled,
            notes: "Unsupported in the current app."
        )
        let snapshot = MenuStatusSnapshot.make(
            accessibilityTrusted: true,
            inputMonitoringAllowed: true,
            backendStatusSummary: .connected,
            inputMethod: .init(summary: "ASCII", inputSourceID: nil),
            focus: Self.focus(),
            focusFailure: nil,
            compatibilityDecision: decision,
            autocompleteEnabled: true
        )

        XCTAssertEqual(try item("focus", in: snapshot).value, "Blocked")
        XCTAssertEqual(try item("mode", in: snapshot).value, "Disabled")
        XCTAssertEqual(try item("focus", in: snapshot).action, "Unsupported in the current app.")
    }

    func testLastDecisionIsVisibleInStatusRows() throws {
        let snapshot = MenuStatusSnapshot.make(
            accessibilityTrusted: true,
            inputMonitoringAllowed: true,
            backendStatusSummary: .connected,
            inputMethod: .init(summary: "ASCII", inputSourceID: nil),
            focus: Self.focus(),
            focusFailure: nil,
            lastDecision: SuggestionDiagnostics.LastDecision(
                state: .waiting,
                reason: .manualTriggerOnly,
                action: "Use the manual trigger in this app or domain."
            ),
            compatibilityDecision: Self.decision(overrideMode: .manualOnly, allowsAutomaticSuggestions: false),
            autocompleteEnabled: true
        )

        let lastDecision = try item("lastDecision", in: snapshot)
        XCTAssertEqual(lastDecision.value, "Waiting")
        XCTAssertTrue(lastDecision.action.contains("manual-trigger-only"))
        XCTAssertTrue(lastDecision.action.contains("manual trigger"))
    }

    func testProductivityMetricsSummaryShowsOnlyLocalCounters() throws {
        let snapshot = MenuStatusSnapshot.make(
            accessibilityTrusted: true,
            inputMonitoringAllowed: true,
            backendStatusSummary: .connected,
            inputMethod: .init(summary: "ASCII", inputSourceID: nil),
            focus: Self.focus(),
            focusFailure: nil,
            compatibilityDecision: Self.decision(),
            autocompleteEnabled: true,
            productivityMetrics: ProductivityMetricsSnapshot(
                isEnabled: true,
                dayKey: "2026-05-27",
                wordsAcceptedToday: 7,
                wordsAcceptedTotal: 20,
                suggestionsAccepted: 5,
                suggestionsDismissed: 2,
                latencySampleCount: 3,
                averageBackendLatencyMs: 42
            )
        )

        let metrics = try item("metrics", in: snapshot)
        XCTAssertEqual(metrics.value, "7 words today")
        XCTAssertTrue(metrics.action.contains("20 total words"))
        XCTAssertTrue(metrics.action.contains("5 accepted"))
        XCTAssertTrue(metrics.action.contains("2 dismissed"))
        XCTAssertTrue(metrics.action.contains("42 ms average"))
        XCTAssertFalse(metrics.action.contains("typed secret"))
    }

    func testStatusRowsDoNotExposeUserTextOrInputSourceIdentifier() {
        let snapshot = MenuStatusSnapshot.make(
            accessibilityTrusted: true,
            inputMonitoringAllowed: true,
            backendStatusSummary: .connected,
            inputMethod: .init(summary: "non-ASCII", inputSourceID: "com.apple.private.input-source"),
            focus: Self.focus(),
            focusFailure: nil,
            lastDecision: SuggestionDiagnostics.LastDecision(
                state: .skipped,
                reason: .noMeaningfulPrefix,
                action: "Type a meaningful prefix before requesting a suggestion."
            ),
            compatibilityDecision: Self.decision(),
            autocompleteEnabled: true
        )

        let combined = snapshot.items
            .flatMap { [$0.title, $0.value, $0.action] }
            .joined(separator: "\n")
        XCTAssertFalse(combined.contains("private.input-source"))
        XCTAssertFalse(combined.contains("typed secret"))
        XCTAssertEqual(snapshot.items.first { $0.id == "ime" }?.value, "non-ASCII")
    }

    private func item(_ id: String, in snapshot: MenuStatusSnapshot) throws -> MenuStatusItem {
        try XCTUnwrap(snapshot.items.first { $0.id == id })
    }

    private static func focus() -> SuggestionDiagnostics.Focus {
        SuggestionDiagnostics.Focus(
            appDisplayName: "TextEdit",
            bundleID: "com.apple.TextEdit",
            domain: nil,
            focusedElementID: "field",
            contextSource: "Accessibility",
            geometryQuality: "direct",
            contextTrust: "standard",
            contextWarning: nil,
            hasCaretRect: true,
            hasFocusedElementRect: true
        )
    }

    private static func decision(
        status: CompatibilityStatus = .works,
        mode: SuggestionDisplayMode = .inline,
        enabled: Bool = true,
        overrideMode: CompatibilityOverrideMode = .automatic,
        allowsAutomaticSuggestions: Bool = true,
        notes: String = ""
    ) -> CompatibilityDecision {
        CompatibilityDecision(
            profile: AppCompatibilityProfile(
                bundleID: "com.apple.TextEdit",
                displayName: "TextEdit",
                status: status,
                defaultMode: mode,
                notes: notes,
                defaultActivationMode: overrideMode
            ),
            mode: mode,
            enabled: enabled,
            overrideMode: overrideMode,
            allowsAutomaticSuggestions: allowsAutomaticSuggestions
        )
    }
}
