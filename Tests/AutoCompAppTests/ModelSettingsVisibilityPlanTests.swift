import XCTest
import AutoCompCore

final class ModelSettingsVisibilityPlanTests: XCTestCase {
    func testRemoteVisibilityPlanShowsRemoteSetupAndHidesLocalSetup() {
        let plan = CompletionEngineKind.remote.settingsVisibilityPlanUnderTest

        XCTAssertTrue(plan.isVisible(.backendSelection, showAdvanced: false))
        XCTAssertTrue(plan.isVisible(.remoteConsent, showAdvanced: false))
        XCTAssertTrue(plan.isVisible(.remoteBackend, showAdvanced: false))

        XCTAssertFalse(plan.isVisible(.localModel, showAdvanced: false))
        XCTAssertFalse(plan.isVisible(.appleIntelligence, showAdvanced: false))
        XCTAssertFalse(plan.isVisible(.recommendedLocalModels, showAdvanced: false))

        XCTAssertFalse(plan.isVisible(.diagnostics, showAdvanced: false))
        XCTAssertTrue(plan.isVisible(.diagnostics, showAdvanced: true))
    }

    func testLocalVisibilityPlanShowsLocalSetupAndAllowsRemoteFallbackSetup() {
        let plan = CompletionEngineKind.localLlama.settingsVisibilityPlanUnderTest

        XCTAssertTrue(plan.isVisible(.backendSelection, showAdvanced: false))
        XCTAssertTrue(plan.isVisible(.localModel, showAdvanced: false))

        // Remote settings must remain visible to configure fallback.
        XCTAssertTrue(plan.isVisible(.remoteBackend, showAdvanced: false))

        XCTAssertFalse(plan.isVisible(.remoteConsent, showAdvanced: false))
        XCTAssertFalse(plan.isVisible(.appleIntelligence, showAdvanced: false))

        XCTAssertFalse(plan.isVisible(.recommendedLocalModels, showAdvanced: false))
        XCTAssertTrue(plan.isVisible(.recommendedLocalModels, showAdvanced: true))
    }

    func testAppleIntelligenceVisibilityPlanShowsAppleSetupAndAllowsRemoteFallbackSetup() {
        let plan = CompletionEngineKind.appleIntelligence.settingsVisibilityPlanUnderTest

        XCTAssertTrue(plan.isVisible(.backendSelection, showAdvanced: false))
        XCTAssertTrue(plan.isVisible(.appleIntelligence, showAdvanced: false))

        // Remote settings must remain visible to configure fallback.
        XCTAssertTrue(plan.isVisible(.remoteBackend, showAdvanced: false))

        XCTAssertFalse(plan.isVisible(.remoteConsent, showAdvanced: false))
        XCTAssertFalse(plan.isVisible(.localModel, showAdvanced: false))
    }
}
