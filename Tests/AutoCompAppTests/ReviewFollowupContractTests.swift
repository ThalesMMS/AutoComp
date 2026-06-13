@testable import AutoCompApp
import XCTest

final class ReviewFollowupContractTests: XCTestCase {
    func testAppControllerReplaysConsumedTabWhenAcceptNextWordPassesThrough() throws {
        let source = try sourceFile("Sources/AutoCompApp/App/AppController.swift")
        let branchRange = try XCTUnwrap(source.range(of: "if outcome == .passedThrough"))
        let branchSource = String(source[branchRange.lowerBound...])

        XCTAssertTrue(branchSource.contains("keyboardShortcuts.replayPassthroughShortcut(command)"))
        XCTAssertFalse(branchSource.contains("replay=skipped"))
    }

    func testPermissionGuidanceControllerCancelsTimerOnDeinit() throws {
        let source = try sourceFile("Sources/AutoCompApp/Services/Permission/Guidance/PermissionGuidanceController.swift")

        XCTAssertTrue(source.contains("deinit {"))
        XCTAssertTrue(source.contains("refreshTimer?.invalidate()"))
    }

}
