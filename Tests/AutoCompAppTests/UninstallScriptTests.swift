@testable import AutoCompApp
import XCTest

final class UninstallScriptTests: XCTestCase {
    func testUninstallDryRunPreservesLocalStateAndDocumentsPermissionReset() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try runUninstall([
            "--dry-run",
            "--home",
            fixture.home.path,
            "--app-path",
            fixture.extraApp.path,
            "--skip-keychain"
        ])

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("AutoComp uninstall dry run"))
        XCTAssertTrue(result.output.contains("Application Support/AutoComp"))
        XCTAssertTrue(result.output.contains("System Settings > Privacy & Security"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.extraApp.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.applicationSupport.path))
    }

    func testUninstallDryRunWorksWithoutExtraAppPath() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let result = try runUninstall([
            "--dry-run",
            "--home",
            fixture.home.path,
            "--skip-keychain"
        ])

        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("AutoComp uninstall dry run"))
        XCTAssertTrue(result.output.contains("System Settings > Privacy & Security"))
    }

    func testUninstallRemovesLocalStateAndIsIdempotent() throws {
        let fixture = try makeFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        let first = try runUninstall([
            "--home",
            fixture.home.path,
            "--app-path",
            fixture.extraApp.path,
            "--skip-keychain"
        ])
        XCTAssertEqual(first.status, 0, first.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.extraApp.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.applicationSupport.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.preferences.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.logs.path))

        let second = try runUninstall([
            "--home",
            fixture.home.path,
            "--app-path",
            fixture.extraApp.path,
            "--skip-keychain"
        ])
        XCTAssertEqual(second.status, 0, second.output)
        XCTAssertTrue(second.output.contains("Already absent"))
    }

    func testUninstallScriptCoversSensitiveStateAndKeychainItems() throws {
        let script = try String(
            contentsOf: try packageRoot().appendingPathComponent("script/uninstall.sh"),
            encoding: .utf8
        )

        for requiredText in [
            "--dry-run",
            "Library/Application Support/$APP_NAME",
            "Library/Caches/$BUNDLE_ID",
            "Library/Logs/$APP_NAME",
            "Library/Preferences/$BUNDLE_ID.plist",
            "com.autocomp.backend",
            "com.autocomp.personalization",
            "System Settings > Privacy & Security"
        ] {
            XCTAssertTrue(script.contains(requiredText), "Missing uninstall coverage: \(requiredText)")
        }
    }

    private func makeFixture() throws -> UninstallFixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("autocomp-uninstall-\(UUID().uuidString)", isDirectory: true)
        let home = root.appendingPathComponent("home", isDirectory: true)
        let extraApp = root.appendingPathComponent("Downloads/AutoComp.app", isDirectory: true)
        let applicationSupport = home
            .appendingPathComponent("Library/Application Support/AutoComp", isDirectory: true)
        let preferences = home
            .appendingPathComponent("Library/Preferences/com.autocomp.AutoComp.plist", isDirectory: false)
        let logs = home
            .appendingPathComponent("Library/Logs/AutoComp", isDirectory: true)

        for directory in [
            extraApp,
            applicationSupport.appendingPathComponent("Models", isDirectory: true),
            applicationSupport.appendingPathComponent("DebugArtifacts", isDirectory: true),
            logs,
            preferences.deletingLastPathComponent()
        ] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        try Data("model".utf8).write(to: applicationSupport.appendingPathComponent("Models/autocomp.gguf"))
        try Data("debug".utf8).write(to: applicationSupport.appendingPathComponent("DebugArtifacts/prompt.txt"))
        try Data("prefs".utf8).write(to: preferences)
        try Data("log".utf8).write(to: logs.appendingPathComponent("autocomp.log"))

        return UninstallFixture(
            root: root,
            home: home,
            extraApp: extraApp,
            applicationSupport: applicationSupport,
            preferences: preferences,
            logs: logs
        )
    }

    private func runUninstall(_ arguments: [String]) throws -> CommandResult {
        let root = try packageRoot()
        let process = Process()
        process.currentDirectoryURL = root
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["script/uninstall.sh"] + arguments

        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()

        let data = output.fileHandleForReading.readDataToEndOfFile()
        return CommandResult(
            status: process.terminationStatus,
            output: String(data: data, encoding: .utf8) ?? ""
        )
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

private struct UninstallFixture {
    let root: URL
    let home: URL
    let extraApp: URL
    let applicationSupport: URL
    let preferences: URL
    let logs: URL
}

private struct CommandResult {
    let status: Int32
    let output: String
}
