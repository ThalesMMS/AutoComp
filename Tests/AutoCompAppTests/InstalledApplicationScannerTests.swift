import AppKit
@testable import AutoCompApp
import XCTest

final class InstalledApplicationScannerTests: XCTestCase {
    func testScannerReadsAppsWithBundleIDAndSkipsMissingBundleID() throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        try makeApp(at: root.appendingPathComponent("Writer.app"), bundleID: "com.example.Writer", displayName: "Writer")
        try makeApp(at: root.appendingPathComponent("NoBundle.app"), bundleID: nil, displayName: "No Bundle")
        try makeApp(
            at: root.appendingPathComponent("Utilities/Helper.app"),
            bundleID: "com.example.Helper",
            displayName: "Helper"
        )

        let scanner = InstalledApplicationScanner(
            roots: [root],
            iconProvider: { _ in NSImage(size: NSSize(width: 16, height: 16)) }
        )

        let apps = scanner.scan()

        XCTAssertEqual(apps.map(\.bundleID).sorted(), ["com.example.Helper", "com.example.Writer"])
        XCTAssertEqual(apps.first { $0.bundleID == "com.example.Writer" }?.displayName, "Writer")
    }

    func testScannerDeduplicatesBundleIDs() throws {
        let root = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: root)
        }
        try makeApp(at: root.appendingPathComponent("First.app"), bundleID: "com.example.Duplicate", displayName: "First")
        try makeApp(at: root.appendingPathComponent("Second.app"), bundleID: "com.example.Duplicate", displayName: "Second")

        let scanner = InstalledApplicationScanner(
            roots: [root],
            iconProvider: { _ in NSImage(size: NSSize(width: 16, height: 16)) }
        )

        XCTAssertEqual(scanner.scan().count, 1)
    }

    func testFilterMatchesDisplayNameAndBundleID() throws {
        let apps = [
            installedApp(displayName: "Mail", bundleID: "com.apple.mail"),
            installedApp(displayName: "Writer", bundleID: "com.example.writer")
        ]

        XCTAssertEqual(
            InstalledApplicationFilter.filter(apps, matching: "mail").map(\.bundleID),
            ["com.apple.mail"]
        )
        XCTAssertEqual(
            InstalledApplicationFilter.filter(apps, matching: "example").map(\.bundleID),
            ["com.example.writer"]
        )
        XCTAssertEqual(InstalledApplicationFilter.filter(apps, matching: "   ").count, 2)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("InstalledApplicationScannerTests")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func makeApp(at appURL: URL, bundleID: String?, displayName: String) throws {
        let contentsURL = appURL.appendingPathComponent("Contents")
        try FileManager.default.createDirectory(at: contentsURL, withIntermediateDirectories: true)
        var plist: [String: Any] = [
            "CFBundleName": displayName
        ]
        if let bundleID {
            plist["CFBundleIdentifier"] = bundleID
        }
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contentsURL.appendingPathComponent("Info.plist"))
    }

    private func installedApp(displayName: String, bundleID: String) -> InstalledApplication {
        InstalledApplication(
            displayName: displayName,
            bundleID: bundleID,
            url: URL(fileURLWithPath: "/Applications/\(displayName).app"),
            icon: NSImage(size: NSSize(width: 16, height: 16))
        )
    }
}
