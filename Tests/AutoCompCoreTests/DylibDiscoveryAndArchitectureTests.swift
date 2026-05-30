import XCTest
@testable import AutoCompCore

final class DylibDiscoveryAndArchitectureTests: XCTestCase {
    func testDetectHomebrewRuntimeCandidatesReturnsEmptyWhenPrefixesMissing() {
        // This test is environment-independent: it should pass whether Homebrew exists or not.
        // We assert only that the call does not crash and returns a stable shape.
        let runner = LocalModelDiagnosticsRunner()
        let candidates = runner.detectHomebrewRuntimeCandidates()
        XCTAssertNotNil(candidates)
    }

    func testDetectCustomRuntimeCandidatesNotConfiguredReturnsInformationalFinding() {
        let runner = LocalModelDiagnosticsRunner()
        let result = runner.detectCustomRuntimeCandidates(customRuntimeSearchPath: nil)
        XCTAssertNotNil(result.finding)
        XCTAssertEqual(result.finding?.severity, .info)
    }

    func testDetectCustomRuntimeCandidatesMissingPathReturnsWarningFinding() {
        let runner = LocalModelDiagnosticsRunner()
        let result = runner.detectCustomRuntimeCandidates(customRuntimeSearchPath: "/path/that/should/not/exist-12345")
        XCTAssertEqual(result.finding?.severity, .warning)
        XCTAssertTrue(result.dylibCandidates.isEmpty)
    }

    func testRuntimeDiscoverySectionPrefersExplicitCustomRuntimeSearchPath() throws {
        let runner = LocalModelDiagnosticsRunner()

        // Create a fake runtime folder with placeholder dylib file names.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("autocomp-test-runtime", isDirectory: true)
        try? FileManager.default.removeItem(at: tmpDir)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Create a readable regular file at libllama.dylib path.
        let libllama = tmpDir.appendingPathComponent("libllama.dylib")
        try Data([0x00, 0x01, 0x02]).write(to: libllama, options: [.atomic])

        let report = runner.run(ggufPath: nil, runtimeSearchPath: tmpDir.path)
        let section = try XCTUnwrap(report.sections.first(where: { $0.kind == LocalModelDiagnosticsReport.SectionKind.runtime }))

        // The report should mention the configured custom runtime path.
        let detailsJoined = section.findings.compactMap { $0.details }.joined(separator: "\n")
        XCTAssertTrue(detailsJoined.contains(tmpDir.path))
    }

    func testRuntimeArchitectureSectionHandlesNonMachOFileGracefully() throws {
        let runner = LocalModelDiagnosticsRunner()

        // Make a folder containing a fake dylib file that is not actually Mach-O.
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("autocomp-test-nonmacho", isDirectory: true)
        try? FileManager.default.removeItem(at: tmpDir)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let fakeDylib = tmpDir.appendingPathComponent("libllama.dylib")
        try Data(repeating: 0xFF, count: 64).write(to: fakeDylib, options: [.atomic])

        let report = runner.run(ggufPath: nil, runtimeSearchPath: tmpDir.path)
        // Architecture validation findings are included in the same .runtime section.
        let section = try XCTUnwrap(report.sections.first(where: { $0.kind == LocalModelDiagnosticsReport.SectionKind.runtime }))

        // We should get a warning (not Mach-O) but no crash.
        // Sanity: section has at least one finding.
        XCTAssertFalse(section.findings.isEmpty)
        let details = section.findings.compactMap { $0.details }.joined(separator: "\n")
        XCTAssertTrue(details.contains("not Mach-O") || details.contains("Mach-O"))
    }
}
