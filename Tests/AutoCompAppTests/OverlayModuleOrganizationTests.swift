import Foundation
import XCTest

final class OverlayModuleOrganizationTests: XCTestCase {
    func testOverlayModulesDoNotUsePlaceholderStubs() throws {
        let overlayRoot = try packageRoot()
            .appendingPathComponent("Sources/AutoCompApp/Services/Overlay")
        let swiftFiles = try recursiveSwiftFiles(in: overlayRoot)

        let stubFiles = swiftFiles
            .map { $0.path.replacingOccurrences(of: overlayRoot.path + "/", with: "") }
            .filter { $0.hasSuffix("Stub.swift") }
            .sorted()

        XCTAssertTrue(stubFiles.isEmpty, "Overlay placeholder stubs remain: \(stubFiles.joined(separator: ", "))")

        for file in swiftFiles {
            let source = try String(contentsOf: file, encoding: .utf8)
            XCTAssertFalse(source.contains("Intentionally minimal"), file.path)
            XCTAssertFalse(source.contains("later subtasks"), file.path)
        }
    }

    func testOverlaySubmodulesContainRealImplementations() throws {
        let overlayRoot = try packageRoot()
            .appendingPathComponent("Sources/AutoCompApp/Services/Overlay")

        for submodule in ["AppKit", "Geometry", "Layout", "Presenters", "Views"] {
            let directory = overlayRoot.appendingPathComponent(submodule)
            var isDirectory: ObjCBool = false
            let directoryExists = FileManager.default.fileExists(
                atPath: directory.path,
                isDirectory: &isDirectory
            )
            XCTAssertTrue(
                directoryExists && isDirectory.boolValue,
                "\(submodule) overlay submodule directory is missing: \(directory.path)"
            )
            let implementationFiles = try recursiveSwiftFiles(in: directory)
                .map(\.lastPathComponent)
                .filter { !$0.hasSuffix("Stub.swift") }

            XCTAssertFalse(implementationFiles.isEmpty, "\(submodule) has no concrete overlay implementation files")
        }
    }

    private func recursiveSwiftFiles(in directory: URL) throws -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        return try enumerator.compactMap { entry in
            let url = try XCTUnwrap(entry as? URL)
            let values = try url.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true, url.pathExtension == "swift" else {
                return nil
            }
            return url
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
