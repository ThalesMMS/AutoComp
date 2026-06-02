import AppKit
@testable import AutoCompApp
import XCTest

@MainActor
final class AppActivationPolicyControllerTests: XCTestCase {
    func testEmptyControllerStartsAccessory() {
        let applier = FakeActivationPolicyApplier()
        let controller = AppActivationPolicyController(applier: applier)

        XCTAssertEqual(controller.currentPolicy, .accessory)
        XCTAssertEqual(controller.visibleWindowCount, 0)
        XCTAssertTrue(applier.setPolicies.isEmpty)
    }

    func testFirstWindowPromotesToRegularAndActivates() {
        let applier = FakeActivationPolicyApplier()
        let controller = AppActivationPolicyController(applier: applier)

        controller.windowDidOpen(.settings)

        XCTAssertEqual(controller.currentPolicy, .regular)
        XCTAssertTrue(controller.contains(.settings))
        XCTAssertEqual(applier.setPolicies, [.regular])
        XCTAssertEqual(applier.activationCount, 1)
    }

    func testSecondWindowKeepsRegularUntilLastWindowCloses() {
        let applier = FakeActivationPolicyApplier()
        let controller = AppActivationPolicyController(applier: applier)

        controller.windowDidOpen(.settings)
        controller.windowDidOpen(.onboarding)
        controller.windowDidClose(.settings)

        XCTAssertEqual(controller.currentPolicy, .regular)
        XCTAssertFalse(controller.contains(.settings))
        XCTAssertTrue(controller.contains(.onboarding))
        XCTAssertEqual(applier.setPolicies, [.regular])

        controller.windowDidClose(.onboarding)

        XCTAssertEqual(controller.currentPolicy, .accessory)
        XCTAssertEqual(controller.visibleWindowCount, 0)
        XCTAssertEqual(applier.setPolicies, [.regular, .accessory])
    }

    func testDuplicateOpenAndCloseCallsAreIdempotentForPolicyState() {
        let applier = FakeActivationPolicyApplier()
        let controller = AppActivationPolicyController(applier: applier)

        controller.windowDidOpen(.settings)
        controller.windowDidOpen(.settings)
        controller.windowDidClose(.settings)
        controller.windowDidClose(.settings)

        XCTAssertEqual(controller.currentPolicy, .accessory)
        XCTAssertEqual(controller.visibleWindowCount, 0)
        XCTAssertEqual(applier.setPolicies, [.regular, .accessory])
    }
}

@MainActor
private final class FakeActivationPolicyApplier: AppActivationPolicyApplying {
    private(set) var setPolicies: [NSApplication.ActivationPolicy] = []
    private(set) var activationCount = 0

    func setActivationPolicy(_ policy: NSApplication.ActivationPolicy) {
        setPolicies.append(policy)
    }

    func activateIgnoringOtherApps() {
        activationCount += 1
    }
}
