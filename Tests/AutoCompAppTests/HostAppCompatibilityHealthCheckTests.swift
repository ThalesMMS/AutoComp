import XCTest
@testable import AutoCompApp
import AutoCompCore

final class HostAppCompatibilityHealthCheckTests: XCTestCase {
    func testEvaluate_whenNoSnapshot_returnsUnknownWithNoActions() {
        let check = HostAppCompatibilityHealthCheck(snapshotProvider: { nil })
        let result = check.evaluate()

        XCTAssertEqual(result.id, HostAppCompatibilityHealthCheck.id)
        XCTAssertEqual(result.status, .unknown)
        XCTAssertEqual(result.summary, "No focused app")
        XCTAssertTrue(result.actions.isEmpty)
    }

    func testEvaluate_whenUnsupportedProfile_reportsFailDisabled_andIncludesBundleID_andSettingsAction() {
        let snapshot = FocusTrackingSnapshot(
            context: TextContext(
                app: AppIdentity(bundleID: "org.mozilla.thunderbird", displayName: "Thunderbird", processID: 0),
                domain: nil,
                focusedElementID: "el",
                textBeforeCursor: ""
            ),
            stableFieldIdentity: nil,
            focusChangeSequence: 1,
            capability: .readableText,
            rejectionReason: nil
        )
        let check = HostAppCompatibilityHealthCheck(
            snapshotProvider: { snapshot },
            compatibilityCatalog: CompatibilityCatalog(),
            compatibilitySettingsStore: CompatibilitySettingsStoreMock(modeOverrides: [:])
        )

        let result = check.evaluate()

        XCTAssertEqual(result.status, .fail)
        XCTAssertEqual(result.summary, "Disabled")
        XCTAssertTrue((result.details ?? "").contains("Thunderbird"))
        XCTAssertTrue((result.details ?? "").contains("org.mozilla.thunderbird"))
        XCTAssertTrue(result.actions.contains(HealthRemediationCatalog.openCompatibilitySettings))
    }

    func testEvaluate_whenManualOnlyOverride_reportsWarn_andMentionsManualTrigger() {
        let snapshot = FocusTrackingSnapshot(
            context: TextContext(
                app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 0),
                domain: nil,
                focusedElementID: "el",
                textBeforeCursor: ""
            ),
            stableFieldIdentity: nil,
            focusChangeSequence: 1,
            capability: .readableText,
            rejectionReason: nil
        )

        let overrides: [String: CompatibilityOverrideMode] = [
            "com.apple.TextEdit": .manualOnly
        ]

        let check = HostAppCompatibilityHealthCheck(
            snapshotProvider: { snapshot },
            compatibilityCatalog: CompatibilityCatalog(),
            compatibilitySettingsStore: CompatibilitySettingsStoreMock(modeOverrides: overrides)
        )

        let result = check.evaluate()

        XCTAssertEqual(result.status, .warn)
        XCTAssertEqual(result.summary, "Manual only")
        XCTAssertTrue((result.details ?? "").contains("manual trigger"))
        XCTAssertTrue(result.actions.contains(HealthRemediationCatalog.openCompatibilitySettings))
    }

    func testEvaluate_whenDisabledOverride_reportsFailDisabled() {
        let snapshot = FocusTrackingSnapshot(
            context: TextContext(
                app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 0),
                domain: nil,
                focusedElementID: "el",
                textBeforeCursor: ""
            ),
            stableFieldIdentity: nil,
            focusChangeSequence: 1,
            capability: .readableText,
            rejectionReason: nil
        )

        let overrides: [String: CompatibilityOverrideMode] = [
            "com.apple.TextEdit": .disabled
        ]

        let check = HostAppCompatibilityHealthCheck(
            snapshotProvider: { snapshot },
            compatibilityCatalog: CompatibilityCatalog(),
            compatibilitySettingsStore: CompatibilitySettingsStoreMock(modeOverrides: overrides)
        )

        let result = check.evaluate()

        XCTAssertEqual(result.status, .fail)
        XCTAssertEqual(result.summary, "Disabled")
        XCTAssertTrue(result.actions.contains(HealthRemediationCatalog.openCompatibilitySettings))
    }

    func testEvaluate_whenAutomatic_reportsOkEnabled_andIncludesSettingsAction() {
        let snapshot = FocusTrackingSnapshot(
            context: TextContext(
                app: AppIdentity(bundleID: "com.apple.TextEdit", displayName: "TextEdit", processID: 0),
                domain: nil,
                focusedElementID: "el",
                textBeforeCursor: ""
            ),
            stableFieldIdentity: nil,
            focusChangeSequence: 1,
            capability: .readableText,
            rejectionReason: nil
        )
        let check = HostAppCompatibilityHealthCheck(
            snapshotProvider: { snapshot },
            compatibilityCatalog: CompatibilityCatalog(),
            compatibilitySettingsStore: CompatibilitySettingsStoreMock(modeOverrides: [:])
        )

        let result = check.evaluate()

        XCTAssertEqual(result.status, .ok)
        XCTAssertEqual(result.summary, "Enabled")
        XCTAssertTrue(result.actions.contains(HealthRemediationCatalog.openCompatibilitySettings))
    }
}



private struct CompatibilitySettingsStoreMock: CompatibilitySettingsStoreReading {
    let modeOverrides: [String: CompatibilityOverrideMode]

    func loadModeOverrides() -> [String: CompatibilityOverrideMode] {
        modeOverrides
    }
}
