@testable import AutoCompApp
import XCTest

final class InteractionPipelineSuspensionControllerTests: XCTestCase {
    func testWithPipelineSuspendedResumesAfterSuccess() {
        let controller = InteractionPipelineSuspensionController()
        var states: [Bool] = []
        controller.addStateChangeHandler { isSuspended, _ in
            states.append(isSuspended)
        }

        let value = controller.withPipelineSuspended(reason: .openPanel) {
            XCTAssertTrue(controller.isSuspended)
            XCTAssertEqual(controller.activeReasons, [.openPanel])
            return 42
        }

        XCTAssertEqual(value, 42)
        XCTAssertFalse(controller.isSuspended)
        XCTAssertEqual(states, [false, true, false])
    }

    func testWithPipelineSuspendedResumesAfterError() {
        let controller = InteractionPipelineSuspensionController()

        XCTAssertThrowsError(
            try controller.withPipelineSuspended(reason: .settingsImport) {
                XCTAssertTrue(controller.isSuspended)
                throw TestError.expected
            }
        ) { error in
            XCTAssertEqual(error as? TestError, .expected)
        }

        XCTAssertFalse(controller.isSuspended)
        XCTAssertEqual(controller.activeDepth, 0)
    }

    func testNestedSuspensionsDoNotResumeEarly() {
        let controller = InteractionPipelineSuspensionController()
        let outer = controller.suspend(reason: .openPanel)
        let inner = controller.suspend(reason: .modelImport)

        XCTAssertTrue(controller.isSuspended)
        XCTAssertEqual(controller.activeDepth, 2)
        XCTAssertEqual(controller.activeReasons, [.openPanel, .modelImport])

        controller.resume(outer)

        XCTAssertTrue(controller.isSuspended)
        XCTAssertEqual(controller.activeDepth, 1)
        XCTAssertEqual(controller.activeReasons, [.modelImport])

        controller.resume(inner)

        XCTAssertFalse(controller.isSuspended)
        XCTAssertEqual(controller.activeDepth, 0)
    }

    func testResumeByReasonClearsOneMatchingSuspension() {
        let controller = InteractionPipelineSuspensionController()
        var states: [Bool] = []
        var reasons: [Set<InteractionPipelineSuspensionReason>] = []
        controller.addStateChangeHandler { isSuspended, activeReasons in
            states.append(isSuspended)
            reasons.append(activeReasons)
        }

        _ = controller.suspend(reason: .settingsExport)
        _ = controller.suspend(reason: .settingsExport)

        controller.resume(reason: .settingsExport)

        XCTAssertTrue(controller.isSuspended)
        XCTAssertEqual(controller.activeDepth, 1)
        XCTAssertEqual(controller.activeReasons, [.settingsExport])

        controller.resume(reason: .settingsExport)

        XCTAssertFalse(controller.isSuspended)
        XCTAssertEqual(controller.activeDepth, 0)
        XCTAssertEqual(controller.activeReasons, [])
        XCTAssertEqual(states, [false, true, false])
        XCTAssertEqual(reasons, [[], [.settingsExport], []])
    }

    private enum TestError: Error, Equatable {
        case expected
    }
}
