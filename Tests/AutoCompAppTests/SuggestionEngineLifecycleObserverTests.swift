import AutoCompCore
@testable import AutoCompApp
import XCTest

final class SuggestionEngineLifecycleObserverTests: XCTestCase {
    @MainActor
    func testStartStopRegistersAndUnregistersWorkspaceObservers() {
        let notificationCenter = NotificationCenter()
        let controller = SuggestionLifecycleController(notificationCenter: notificationCenter)

        var activeAppChangedCount = 0
        var focusChangedCount = 0

        controller.onActiveAppChanged = {
            activeAppChangedCount += 1
        }
        controller.onFocusChanged = {
            focusChangedCount += 1
        }

        controller.start()

        notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        XCTAssertEqual(activeAppChangedCount, 1)
        XCTAssertEqual(focusChangedCount, 1)

        notificationCenter.post(name: NSWorkspace.didDeactivateApplicationNotification, object: nil)
        XCTAssertEqual(activeAppChangedCount, 1)
        XCTAssertEqual(focusChangedCount, 2)

        controller.stop()

        notificationCenter.post(name: NSWorkspace.didActivateApplicationNotification, object: nil)
        notificationCenter.post(name: NSWorkspace.didDeactivateApplicationNotification, object: nil)
        XCTAssertEqual(activeAppChangedCount, 1)
        XCTAssertEqual(focusChangedCount, 2)
    }
}
