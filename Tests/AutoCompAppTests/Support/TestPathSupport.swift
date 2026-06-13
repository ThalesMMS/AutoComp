import Foundation
import XCTest

extension XCTestCase {
    func packageRoot() throws -> URL {
        var url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        while url.path != "/" {
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("Package.swift").path) {
                return url
            }
            url.deleteLastPathComponent()
        }

        throw XCTSkip("Unable to locate package root")
    }

    func sourceFile(_ relativePath: String) throws -> String {
        try String(contentsOf: try packageRoot().appendingPathComponent(relativePath), encoding: .utf8)
    }

    func source(root: URL, path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }
}
