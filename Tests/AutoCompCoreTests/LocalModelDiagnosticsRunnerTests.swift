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

    func testParseGGUFHeaderUsesQwenArchitectureContextLength() throws {
        let runner = LocalModelDiagnosticsRunner()
        let tmp = try makeGGUFFile(metadata: [
            .string("general.architecture", "qwen3"),
            .uint32("qwen3.context_length", 32768),
            .uint32("general.file_type", 15)
        ])
        defer { try? FileManager.default.removeItem(at: tmp) }

        let header = try runner.parseGGUFHeader(atPath: tmp.path)

        XCTAssertEqual(header.architecture, "qwen3")
        XCTAssertEqual(header.contextLength, 32768)
        XCTAssertEqual(header.quantization, "Q4_K_M")
    }

    func testRunUsesArchitectureContextLengthForMemoryEstimate() throws {
        let runner = LocalModelDiagnosticsRunner()
        let tmp = try makeGGUFFile(metadata: [
            .string("general.architecture", "qwen3"),
            .uint32("qwen3.context_length", 32768),
            .uint32("general.file_type", 15)
        ])
        defer { try? FileManager.default.removeItem(at: tmp) }

        let report = runner.run(ggufPath: tmp.path)
        let memoryFinding = try XCTUnwrap(report.sections.first(where: { $0.kind == .memory })?.findings.first)

        XCTAssertTrue(memoryFinding.details?.contains("KV cache estimated from context length 32768.") == true)
        XCTAssertFalse(memoryFinding.details?.contains("Context length unknown; assumed 4096.") == true)
        XCTAssertNil(memoryFinding.remediation)
    }

    func testParseGGUFHeaderUsesGemmaArchitectureContextLength() throws {
        let runner = LocalModelDiagnosticsRunner()
        let tmp = try makeGGUFFile(metadata: [
            .string("general.architecture", "gemma"),
            .uint32("gemma.context_length", 8192),
            .uint32("general.file_type", 15)
        ])
        defer { try? FileManager.default.removeItem(at: tmp) }

        let header = try runner.parseGGUFHeader(atPath: tmp.path)

        XCTAssertEqual(header.architecture, "gemma")
        XCTAssertEqual(header.contextLength, 8192)
        XCTAssertEqual(header.quantization, "Q4_K_M")
    }

    func testParseGGUFHeaderKeepsLlamaContextLengthFallback() throws {
        let runner = LocalModelDiagnosticsRunner()
        let tmp = try makeGGUFFile(metadata: [
            .string("general.architecture", "qwen3"),
            .uint32("llama.context_length", 4096),
            .uint32("general.file_type", 15)
        ])
        defer { try? FileManager.default.removeItem(at: tmp) }

        let header = try runner.parseGGUFHeader(atPath: tmp.path)

        XCTAssertEqual(header.architecture, "qwen3")
        XCTAssertEqual(header.contextLength, 4096)
        XCTAssertEqual(header.quantization, "Q4_K_M")
    }

    func testParseGGUFHeaderBoundsTruncatedArraySkipWork() throws {
        let runner = LocalModelDiagnosticsRunner()
        let tmp = try makeGGUFFile(metadata: [
            .truncatedArray(
                key: "tokenizer.ggml.tokens",
                elementType: 10,
                declaredLength: 5_000_000,
                trailingBytes: 7
            )
        ])
        defer { try? FileManager.default.removeItem(at: tmp) }

        let startedAt = Date()
        let header = try runner.parseGGUFHeader(atPath: tmp.path)
        let elapsed = Date().timeIntervalSince(startedAt)

        XCTAssertLessThan(elapsed, 0.25)
        XCTAssertNil(header.architecture)
        XCTAssertNil(header.contextLength)
        XCTAssertNil(header.quantization)
    }

    private enum GGUFMetadataEntry {
        case string(String, String)
        case uint32(String, UInt32)
        case truncatedArray(key: String, elementType: UInt32, declaredLength: UInt64, trailingBytes: Int)
    }

    private func makeGGUFFile(metadata: [GGUFMetadataEntry]) throws -> URL {
        var data = Data()
        data.append(contentsOf: [0x47, 0x47, 0x55, 0x46])
        data.appendUInt32(3)
        data.appendUInt64(0)
        data.appendUInt64(UInt64(metadata.count))

        for entry in metadata {
            switch entry {
            case let .string(key, value):
                data.appendGGUFString(key)
                data.appendUInt32(8)
                data.appendGGUFString(value)
            case let .uint32(key, value):
                data.appendGGUFString(key)
                data.appendUInt32(4)
                data.appendUInt32(value)
            case let .truncatedArray(key, elementType, declaredLength, trailingBytes):
                data.appendGGUFString(key)
                data.appendUInt32(9)
                data.appendUInt32(elementType)
                data.appendUInt64(declaredLength)
                data.append(Data(repeating: 0, count: trailingBytes))
            }
        }

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("gguf")
        try data.write(to: tmp, options: [.atomic])
        return tmp
    }
}

private extension Data {
    mutating func appendUInt32(_ value: UInt32) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendUInt64(_ value: UInt64) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }

    mutating func appendGGUFString(_ value: String) {
        let bytes = Data(value.utf8)
        appendUInt64(UInt64(bytes.count))
        append(bytes)
    }
}
