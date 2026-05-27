@testable import AutoCompApp
import Foundation
import XCTest

final class LocalStorageRoadmapTests: XCTestCase {
    func testRoadmapDocumentsMigrationBoundaryRetentionAndDeleteAll() throws {
        let roadmap = try String(
            contentsOf: packageRoot().appendingPathComponent("Docs/LocalStorageRoadmap.md"),
            encoding: .utf8
        )

        XCTAssertTrue(roadmap.contains("AutoComp will not add GRDB or any SQLite dependency yet."))
        XCTAssertTrue(roadmap.contains("## Migration Triggers"))
        XCTAssertTrue(roadmap.contains("UserDefaults"))
        XCTAssertTrue(roadmap.contains("Encrypted JSON files"))
        XCTAssertTrue(roadmap.contains("SQLite/GRDB"))
        XCTAssertTrue(roadmap.contains("Per-record encryption"))
        XCTAssertTrue(roadmap.contains("## Data Never Stored"))
        XCTAssertTrue(roadmap.contains("Raw user documents"))
        XCTAssertTrue(roadmap.contains("## Retention Limits"))
        XCTAssertTrue(roadmap.contains("## Compression Policy"))
        XCTAssertTrue(roadmap.contains("larger than 64 KB"))
        XCTAssertTrue(roadmap.contains("larger than 10 MB"))
        XCTAssertTrue(roadmap.contains("compress -> encrypt"))
        XCTAssertTrue(roadmap.contains("decrypt -> decompress"))
        XCTAssertTrue(roadmap.contains("Never use compression as a substitute for short retention"))
        XCTAssertTrue(roadmap.contains("## Delete-All Strategy"))
        XCTAssertTrue(roadmap.contains("Settings > Privacy"))
        XCTAssertTrue(roadmap.contains("do not add GRDB to Package.swift"))
        XCTAssertTrue(roadmap.contains("do not add Zstandard to Package.swift"))
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
