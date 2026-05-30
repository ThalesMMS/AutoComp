import XCTest
@testable import AutoCompCore

final class LocalModelDiagnosticsRunnerTests: XCTestCase {
    func testGGUFNotConfiguredIsWarning() {
        let runner = LocalModelDiagnosticsRunner()
        let report = runner.run(ggufPath: nil)
        XCTAssertTrue(report.sections.contains(where: { $0.kind == .ggufFile }))
        let ggufSection = report.sections.first(where: { $0.kind == .ggufFile })
        XCTAssertTrue(ggufSection?.findings.contains(where: { $0.severity == .warning }) == true)
    }

    func testGGUFPathMissingIsError() {
        let runner = LocalModelDiagnosticsRunner()
        let report = runner.run(ggufPath: "/path/that/should/not/exist-12345.gguf")
        XCTAssertTrue(report.sections[0].findings.contains(where: { $0.severity == .error }))
    }

    func testGGUFExistingFileIsInfoAndIncludesSize() throws {
        let runner = LocalModelDiagnosticsRunner()

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("autocomp-test-model.gguf")
        try Data(repeating: 0xAB, count: 1024).write(to: tmp, options: [.atomic])
        defer { try? FileManager.default.removeItem(at: tmp) }

        let report = runner.run(ggufPath: tmp.path)
        let finding = try XCTUnwrap(report.sections.first?.findings.first)
        XCTAssertEqual(finding.severity, .info)
        XCTAssertNotNil(finding.details)
        XCTAssertTrue(finding.details?.contains("Size:") == true)
    }
}
