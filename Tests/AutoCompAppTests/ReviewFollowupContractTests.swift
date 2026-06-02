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

    private func sourceFile(_ relativePath: String) throws -> String {
        try String(contentsOf: try packageRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    private func packageRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url.deleteLastPathComponent()
        }

        throw XCTSkip("Unable to locate package root")
    }
}
