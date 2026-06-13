import Foundation
import XCTest

final class TestSupportConsolidationTests: XCTestCase {
    func testPackageRootHelperOnlyLivesInSharedSupportFiles() throws {
        let testsRoot = try packageRoot().appendingPathComponent("Tests")
        let offenders = try recursiveSwiftFiles(in: testsRoot)
            .filter { !allowedPackageRootSupportFiles.contains(relativePath(for: $0, under: testsRoot)) }
            .filter { sourceURL in
                let source = try source(at: sourceURL)
                let privateDeclaration = "\n    private func " + "packageRoot("
                let instanceDeclaration = "\n    func " + "packageRoot("
                let staticDeclaration = "\n    static func " + "packageRoot("
                return source.contains(privateDeclaration)
                    || source.contains(instanceDeclaration)
                    || source.contains(staticDeclaration)
            }
            .map { relativePath(for: $0, under: testsRoot) }
            .sorted()

        XCTAssertEqual(offenders, [])
    }

    func testCoreTextEditContextFixtureOnlyLivesInSharedSupport() throws {
        let testsRoot = try packageRoot().appendingPathComponent("Tests")
        let coreTestsRoot = testsRoot.appendingPathComponent("AutoCompCoreTests")
        let offenders = try recursiveSwiftFiles(in: coreTestsRoot)
            .filter { relativePath(for: $0, under: testsRoot) != "AutoCompCoreTests/Support/CoreTestFixtures.swift" }
            .filter { sourceURL in
                let source = try source(at: sourceURL)
                let contextDeclaration = "\n    private func " + "makeContext("
                return source.contains(contextDeclaration)
                    && source.contains("com.apple.TextEdit")
                    && source.contains("focusedElementID: \"field\"")
            }
            .map { relativePath(for: $0, under: testsRoot) }
            .sorted()

        XCTAssertEqual(offenders, [])
    }

    private var allowedPackageRootSupportFiles: Set<String> {
        [
            "AutoCompAppTests/Support/TestPathSupport.swift",
            "AutoCompCoreTests/Support/CoreTestFixtures.swift"
        ]
    }

    private func source(at url: URL) throws -> String {
        try String(contentsOf: url, encoding: .utf8)
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

    private func relativePath(for url: URL, under root: URL) -> String {
        url.path.replacingOccurrences(of: root.path + "/", with: "")
    }
}
