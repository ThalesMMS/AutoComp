@testable import AutoCompApp
import Foundation
import XCTest

final class DependencyDecisionsTests: XCTestCase {
    func testDependencyDecisionsDocumentStatusesAndTriggers() throws {
        let document = try String(
            contentsOf: try packageRoot().appendingPathComponent("Docs/DependencyDecisions.md"),
            encoding: .utf8
        )

        for requiredText in [
            "## Accepted Dependencies",
            "## Deferred Dependencies",
            "SwiftProtobuf",
            "Defer until binary protocol/daemon",
            "CwlUtils",
            "Defer; prefer internal helpers",
            "Sparkle",
            "Sentry",
            "GRDB",
            "Zstandard",
            "MASShortcut",
            "## Package Rules",
            "## Reevaluation Checklist"
        ] {
            XCTAssertTrue(document.contains(requiredText), "Missing dependency decision text: \(requiredText)")
        }
    }

    func testDeferredDependenciesAreNotAddedToPackageManifest() throws {
        let package = try String(
            contentsOf: try packageRoot().appendingPathComponent("Package.swift"),
            encoding: .utf8
        )

        for deferredDependency in [
            "SwiftProtobuf",
            "CwlUtils",
            "Sentry",
            "GRDB",
            "Zstandard",
            "MASShortcut"
        ] {
            XCTAssertFalse(package.contains(deferredDependency), "Package.swift should not include \(deferredDependency)")
        }
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
