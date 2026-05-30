import Foundation
import Darwin.Mach
import Darwin

public struct LocalModelDiagnosticsRunner: Sendable {
    public struct GGUFHeaderSummary: Equatable, Sendable {
        public let architecture: String?
        public let contextLength: Int?
        public let quantization: String?

        public init(architecture: String?, contextLength: Int?, quantization: String?) {
            self.architecture = architecture
            self.contextLength = contextLength
            self.quantization = quantization
        }
    }

    public enum GGUFHeaderParseError: Error, Equatable, Sendable {
        case fileNotReadable
        case invalidMagic
        case unsupportedFormat
        case ioFailure
    }

    public struct GGUFFileCheckResult: Equatable, Sendable {
        public enum Status: Equatable, Sendable {
            case ok
            case notConfigured
            case missing
            case notAFile
            case unreadable
        }

        public let status: Status
        public let inputPath: String?
        public let resolvedPath: String?
        public let fileSizeBytes: Int64?

        public init(
            status: Status,
            inputPath: String?,
            resolvedPath: String?,
            fileSizeBytes: Int64?
        ) {
            self.status = status
            self.inputPath = inputPath
            self.resolvedPath = resolvedPath
            self.fileSizeBytes = fileSizeBytes
        }
    }

    public init() {}

    public func run(ggufPath: String?, runtimeSearchPath: String? = nil) -> LocalModelDiagnosticsReport {
        let ggufSection = makeGGUFSection(ggufPath: ggufPath)
        let architectureSection = makeArchitectureSection(ggufPath: ggufPath)
        let memorySection = makeMemorySection(ggufPath: ggufPath)
        let memoryFitSection = makeMemoryFitSection(ggufPath: ggufPath)
        let runtimeDiscoverySection = makeRuntimeDiscoverySection(customRuntimeSearchPath: runtimeSearchPath)
        return LocalModelDiagnosticsReport(sections: [
            ggufSection,
            architectureSection,
            memorySection,
            memoryFitSection,
            runtimeDiscoverySection
        ])
    }

    public struct HomebrewRuntimeCandidate: Equatable, Sendable {
        public let prefix: String
        public let librarySearchPaths: [String]
        public let dylibCandidates: [String]

        public init(prefix: String, librarySearchPaths: [String], dylibCandidates: [String]) {
            self.prefix = prefix
            self.librarySearchPaths = librarySearchPaths
            self.dylibCandidates = dylibCandidates
        }
    }

    public struct CustomRuntimeDiscoveryResult: Equatable, Sendable {
        public let normalizedInputPath: String?
        public let resolvedSearchPaths: [String]
        public let dylibCandidates: [String]
        public let finding: LocalModelDiagnosticsReport.Finding?

        public init(
            normalizedInputPath: String?,
            resolvedSearchPaths: [String],
            dylibCandidates: [String],
            finding: LocalModelDiagnosticsReport.Finding?
        ) {
            self.normalizedInputPath = normalizedInputPath
            self.resolvedSearchPaths = resolvedSearchPaths
            self.dylibCandidates = dylibCandidates
            self.finding = finding
        }
    }

    private let knownDylibNames: [String] = [
        "libllama.dylib",
        "libggml.dylib",
        "libggml-base.dylib",
        "libggml-cpu.dylib",
        "libggml-metal.dylib",
        "libggml-blas.dylib"
    ]

    public struct DylibLoadabilityCheckResult: Equatable, Sendable {
        public enum Status: Equatable, Sendable {
            case ok
            case missing
            case notAFile
            case unreadable
            case dlopenFailed
        }

        public let path: String
        public let status: Status
        public let dlopenError: String?

        public init(path: String, status: Status, dlopenError: String?) {
            self.path = path
            self.status = status
            self.dlopenError = dlopenError
        }
    }

    public func detectHomebrewRuntimeCandidates() -> [HomebrewRuntimeCandidate] {
        let prefixes = ["/opt/homebrew", "/usr/local"]
        let fileManager = FileManager.default

        return prefixes.compactMap { prefix in
            var isDir = ObjCBool(false)
            guard fileManager.fileExists(atPath: prefix, isDirectory: &isDir), isDir.boolValue else {
                return nil
            }

            // Common Homebrew lib locations.
            let libDir = prefix + "/lib"
            let optLibDir = prefix + "/opt/llama.cpp/lib"

            let librarySearchPaths = [optLibDir, libDir].filter { path in
                var isDir = ObjCBool(false)
                return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
            }

            // If Homebrew exists but we can't find any plausible lib directory, still surface the prefix.
            var dylibCandidates: [String] = []
            for searchPath in librarySearchPaths {
                for name in knownDylibNames {
                    let candidate = searchPath + "/" + name
                    if fileManager.fileExists(atPath: candidate) {
                        dylibCandidates.append(candidate)
                    }
                }
            }

            return HomebrewRuntimeCandidate(
                prefix: prefix,
                librarySearchPaths: librarySearchPaths,
                dylibCandidates: dylibCandidates
            )
        }
    }

    public func detectCustomRuntimeCandidates(customRuntimeSearchPath: String?) -> CustomRuntimeDiscoveryResult {
        let trimmed = customRuntimeSearchPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = trimmed.flatMap { $0.isEmpty ? nil : $0 }

        guard let normalized else {
            return CustomRuntimeDiscoveryResult(
                normalizedInputPath: nil,
                resolvedSearchPaths: [],
                dylibCandidates: [],
                finding: .init(
                    severity: .info,
                    title: "Custom runtime location not configured",
                    details: "If you built llama.cpp manually, set a folder containing libllama.dylib and related libraries.",
                    remediation: nil
                )
            )
        }

        let expanded = NSString(string: normalized).expandingTildeInPath
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL.path

        let fileManager = FileManager.default
        var isDir = ObjCBool(false)
        guard fileManager.fileExists(atPath: standardized, isDirectory: &isDir), isDir.boolValue else {
            return CustomRuntimeDiscoveryResult(
                normalizedInputPath: normalized,
                resolvedSearchPaths: [standardized],
                dylibCandidates: [],
                finding: .init(
                    severity: .warning,
                    title: "Custom runtime folder not found",
                    details: "Path: \(standardized)",
                    remediation: "Verify the folder exists and contains llama.cpp .dylib files."
                )
            )
        }

        // Search common layouts inside a custom install.
        let candidateDirs = [
            standardized,
            standardized + "/lib",
            standardized + "/build",
            standardized + "/build/lib",
            standardized + "/bin"
        ]

        let searchPaths = candidateDirs.filter { path in
            var isDir = ObjCBool(false)
            return fileManager.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
        }

        var dylibCandidates: [String] = []
        for searchPath in searchPaths {
            for name in knownDylibNames {
                let candidate = searchPath + "/" + name
                if fileManager.fileExists(atPath: candidate) {
                    dylibCandidates.append(candidate)
                }
            }
        }

        let details = "Search paths:\n" + (searchPaths.isEmpty ? "(none)" : searchPaths.joined(separator: "\n"))
            + "\n\nDylib candidates:\n" + (dylibCandidates.isEmpty ? "(no known dylibs found)" : dylibCandidates.joined(separator: "\n"))

        let findingSeverity: LocalModelDiagnosticsReport.Severity = dylibCandidates.isEmpty ? .warning : .info
        let remediation = dylibCandidates.isEmpty
            ? "Ensure the folder contains libllama.dylib and libggml*.dylib. If you built llama.cpp, copy or symlink the dylibs into a single directory and point AutoComp at it."
            : nil

        return CustomRuntimeDiscoveryResult(
            normalizedInputPath: normalized,
            resolvedSearchPaths: searchPaths,
            dylibCandidates: dylibCandidates,
            finding: .init(
                severity: findingSeverity,
                title: "Custom runtime folder configured",
                details: "Path: \(standardized)\n\n" + details,
                remediation: remediation
            )
        )
    }

    public func checkGGUFFile(atPath ggufPath: String?) -> GGUFFileCheckResult {
        let trimmed = ggufPath?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmed, !trimmed.isEmpty else {
            return GGUFFileCheckResult(
                status: .notConfigured,
                inputPath: ggufPath,
                resolvedPath: nil,
                fileSizeBytes: nil
            )
        }

        let expanded = NSString(string: trimmed).expandingTildeInPath
        let standardized = URL(fileURLWithPath: expanded).standardizedFileURL
        let resolvedPath = standardized.path

        var isDirectory = ObjCBool(false)
        guard FileManager.default.fileExists(atPath: resolvedPath, isDirectory: &isDirectory) else {
            return GGUFFileCheckResult(
                status: .missing,
                inputPath: trimmed,
                resolvedPath: resolvedPath,
                fileSizeBytes: nil
            )
        }

        guard !isDirectory.boolValue else {
            return GGUFFileCheckResult(
                status: .notAFile,
                inputPath: trimmed,
                resolvedPath: resolvedPath,
                fileSizeBytes: nil
            )
        }

        let readable = FileManager.default.isReadableFile(atPath: resolvedPath)
        guard readable else {
            return GGUFFileCheckResult(
                status: .unreadable,
                inputPath: trimmed,
                resolvedPath: resolvedPath,
                fileSizeBytes: nil
            )
        }

        let size = (try? FileManager.default.attributesOfItem(atPath: resolvedPath)[.size] as? NSNumber)?.int64Value
        return GGUFFileCheckResult(
            status: .ok,
            inputPath: trimmed,
            resolvedPath: resolvedPath,
            fileSizeBytes: size
        )
    }

    private func makeGGUFSection(ggufPath: String?) -> LocalModelDiagnosticsReport.Section {
        let result = checkGGUFFile(atPath: ggufPath)

        var findings: [LocalModelDiagnosticsReport.Finding] = []

        switch result.status {
        case .notConfigured:
            findings.append(.init(
                severity: .warning,
                title: "No GGUF model selected",
                details: "Choose a local GGUF model file to enable local completions.",
                remediation: "In Settings → Model, pick a .gguf file or download a recommended model."
            ))

        case .missing:
            findings.append(.init(
                severity: .error,
                title: "GGUF model file not found",
                details: "Path: \(result.resolvedPath ?? result.inputPath ?? "(unknown)")",
                remediation: "Verify the file exists, or re-select the model file in Settings."
            ))

        case .notAFile:
            findings.append(.init(
                severity: .error,
                title: "GGUF path is a directory",
                details: "Path: \(result.resolvedPath ?? result.inputPath ?? "(unknown)")",
                remediation: "Select a .gguf file (not a folder)."
            ))

        case .unreadable:
            findings.append(.init(
                severity: .error,
                title: "GGUF model file is not readable",
                details: "Path: \(result.resolvedPath ?? result.inputPath ?? "(unknown)")",
                remediation: "Check file permissions and ensure AutoComp can access the file location."
            ))

        case .ok:
            let sizeLabel: String
            if let bytes = result.fileSizeBytes {
                sizeLabel = ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
            } else {
                sizeLabel = "Unknown size"
            }

            findings.append(.init(
                severity: .info,
                title: "GGUF model file accessible",
                details: "Path: \(result.resolvedPath ?? "(unknown)")\nSize: \(sizeLabel)",
                remediation: nil
            ))
        }

        return LocalModelDiagnosticsReport.Section(
            kind: .ggufFile,
            title: "GGUF model file",
            findings: findings
        )
    }

    private func makeArchitectureSection(ggufPath: String?) -> LocalModelDiagnosticsReport.Section {
        let fileCheck = checkGGUFFile(atPath: ggufPath)
        var findings: [LocalModelDiagnosticsReport.Finding] = []

        guard fileCheck.status == .ok, let path = fileCheck.resolvedPath else {
            return LocalModelDiagnosticsReport.Section(
                kind: .modelArchitecture,
                title: "Model metadata",
                findings: [
                    .init(
                        severity: .info,
                        title: "Model metadata not available",
                        details: "Select a readable .gguf file to inspect architecture and context size.",
                        remediation: nil
                    )
                ]
            )
        }

        do {
            let header = try parseGGUFHeader(atPath: path)
            let detailsLines: [String] = [
                header.architecture.map { "Architecture: \($0)" },
                header.contextLength.map { "Context length: \($0)" },
                header.quantization.map { "Quantization: \($0)" }
            ].compactMap { $0 }

            if detailsLines.isEmpty {
                findings.append(.init(
                    severity: .warning,
                    title: "Unable to extract GGUF metadata",
                    details: "The file looks readable, but required metadata keys were not found.",
                    remediation: "Try re-downloading the model or choose a different GGUF."
                ))
            } else {
                findings.append(.init(
                    severity: .info,
                    title: "GGUF metadata",
                    details: detailsLines.joined(separator: "\n"),
                    remediation: nil
                ))
            }
        } catch {
            findings.append(.init(
                severity: .warning,
                title: "Unable to parse GGUF header",
                details: "\(error)",
                remediation: "Verify the file is a valid .gguf model. If the file is truncated, re-download it."
            ))
        }

        return LocalModelDiagnosticsReport.Section(
            kind: .modelArchitecture,
            title: "Model metadata",
            findings: findings
        )
    }

    private func makeMemorySection(ggufPath: String?) -> LocalModelDiagnosticsReport.Section {
        let fileCheck = checkGGUFFile(atPath: ggufPath)

        guard fileCheck.status == .ok else {
            return LocalModelDiagnosticsReport.Section(
                kind: .memory,
                title: "Memory estimate",
                findings: [
                    .init(
                        severity: .info,
                        title: "Memory estimate not available",
                        details: "Select a readable .gguf file to estimate memory requirements.",
                        remediation: nil
                    )
                ]
            )
        }

        let header = (try? fileCheck.resolvedPath.flatMap { try parseGGUFHeader(atPath: $0) }) ?? nil
        let estimate = estimateMemoryRequirements(
            fileSizeBytes: fileCheck.fileSizeBytes,
            contextLength: header?.contextLength,
            quantizationLabel: header?.quantization
        )

        var details: [String] = []
        if let fileBytes = fileCheck.fileSizeBytes {
            details.append("Weights (file size): \(ByteCountFormatter.string(fromByteCount: fileBytes, countStyle: .memory))")
        }
        details.append("Estimated total RAM needed: \(estimate.totalRangeDescription)")
        details.append("Assumptions: \(estimate.assumptions.joined(separator: " "))")

        var remediation: String? = nil
        if estimate.usesFallbackContextLength {
            remediation = "If the model supports it, reducing context length can lower memory usage. Choosing a smaller quantization (e.g., Q4) also reduces RAM requirements."
        }

        return LocalModelDiagnosticsReport.Section(
            kind: .memory,
            title: "Memory estimate",
            findings: [
                .init(
                    severity: .info,
                    title: "Estimated memory requirements",
                    details: details.joined(separator: "\n"),
                    remediation: remediation
                )
            ]
        )
    }

    public struct DeviceMemorySnapshot: Equatable, Sendable {
        public let totalBytes: Int64
        public let availableBytes: Int64?
        public let pressureLevel: String?

        public init(totalBytes: Int64, availableBytes: Int64?, pressureLevel: String?) {
            self.totalBytes = totalBytes
            self.availableBytes = availableBytes
            self.pressureLevel = pressureLevel
        }
    }

    public enum MemoryFitStatus: String, Equatable, Sendable {
        case ok
        case tight
        case likelyOOM
        case unknown
    }

    public struct MemoryFitResult: Equatable, Sendable {
        public let status: MemoryFitStatus
        public let snapshot: DeviceMemorySnapshot
        public let estimate: MemoryEstimate

        public init(status: MemoryFitStatus, snapshot: DeviceMemorySnapshot, estimate: MemoryEstimate) {
            self.status = status
            self.snapshot = snapshot
            self.estimate = estimate
        }
    }

    public func snapshotDeviceMemory() -> DeviceMemorySnapshot {
        let total = Int64(ProcessInfo.processInfo.physicalMemory)
        let available = queryVMStatPageFreeBytes()
        let pressure = querySystemMemoryPressureLevel()
        return DeviceMemorySnapshot(totalBytes: total, availableBytes: available, pressureLevel: pressure)
    }

    public func evaluateMemoryFit(estimate: MemoryEstimate, snapshot: DeviceMemorySnapshot) -> MemoryFitResult {
        let total = snapshot.totalBytes

        // Prefer available if we can obtain it; else fall back to total RAM heuristics.
        if let available = snapshot.availableBytes, available > 0 {
            // Conservative thresholds:
            // - likely OOM if high estimate exceeds 90% of available
            // - tight if high estimate exceeds 70% of available
            if estimate.totalHighBytes >= Int64(Double(available) * 0.90) {
                return MemoryFitResult(status: .likelyOOM, snapshot: snapshot, estimate: estimate)
            }
            if estimate.totalHighBytes >= Int64(Double(available) * 0.70) {
                return MemoryFitResult(status: .tight, snapshot: snapshot, estimate: estimate)
            }
            return MemoryFitResult(status: .ok, snapshot: snapshot, estimate: estimate)
        }

        // Total-RAM based fallback.
        if total <= 0 {
            return MemoryFitResult(status: .unknown, snapshot: snapshot, estimate: estimate)
        }

        if estimate.totalHighBytes >= Int64(Double(total) * 0.80) {
            return MemoryFitResult(status: .likelyOOM, snapshot: snapshot, estimate: estimate)
        }
        if estimate.totalHighBytes >= Int64(Double(total) * 0.60) {
            return MemoryFitResult(status: .tight, snapshot: snapshot, estimate: estimate)
        }
        return MemoryFitResult(status: .ok, snapshot: snapshot, estimate: estimate)
    }

    private func makeMemoryFitSection(ggufPath: String?) -> LocalModelDiagnosticsReport.Section {
        let fileCheck = checkGGUFFile(atPath: ggufPath)
        guard fileCheck.status == .ok else {
            return LocalModelDiagnosticsReport.Section(
                kind: .memoryFit,
                title: "Memory fit",
                findings: [
                    .init(
                        severity: .info,
                        title: "Memory fit not available",
                        details: "Select a readable .gguf file to check whether it is likely to fit in memory.",
                        remediation: nil
                    )
                ]
            )
        }

        let header = (try? fileCheck.resolvedPath.flatMap { try parseGGUFHeader(atPath: $0) }) ?? nil
        let estimate = estimateMemoryRequirements(
            fileSizeBytes: fileCheck.fileSizeBytes,
            contextLength: header?.contextLength,
            quantizationLabel: header?.quantization
        )

        let snapshot = snapshotDeviceMemory()
        let fit = evaluateMemoryFit(estimate: estimate, snapshot: snapshot)

        let totalLabel = ByteCountFormatter.string(fromByteCount: snapshot.totalBytes, countStyle: .memory)
        let availableLabel = snapshot.availableBytes.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .memory) }

        var detailLines: [String] = []
        detailLines.append("Device RAM (total): \(totalLabel)")
        if let availableLabel {
            detailLines.append("Device RAM (available): \(availableLabel)")
        } else {
            detailLines.append("Device RAM (available): Unknown")
        }
        if let level = snapshot.pressureLevel {
            detailLines.append("Memory pressure: \(level)")
        }
        detailLines.append("Estimated RAM needed: \(estimate.totalRangeDescription)")

        let finding: LocalModelDiagnosticsReport.Finding
        switch fit.status {
        case .ok:
            finding = .init(
                severity: .info,
                title: "Model likely fits in memory",
                details: detailLines.joined(separator: "\n"),
                remediation: nil
            )
        case .tight:
            finding = .init(
                severity: .warning,
                title: "Memory fit is tight",
                details: detailLines.joined(separator: "\n"),
                remediation: "Close other memory-heavy apps, reduce context length, or choose a smaller quantization (e.g., Q4) to improve stability."
            )
        case .likelyOOM:
            finding = .init(
                severity: .error,
                title: "Model likely exceeds available memory",
                details: detailLines.joined(separator: "\n"),
                remediation: "Choose a smaller model/quantization and/or reduce context length. Very large models can cause the app to be terminated by the system."
            )
        case .unknown:
            finding = .init(
                severity: .warning,
                title: "Unable to determine memory fit",
                details: detailLines.joined(separator: "\n"),
                remediation: "If you see crashes or the model fails to load, try a smaller model or reduce context length."
            )
        }

        return LocalModelDiagnosticsReport.Section(
            kind: .memoryFit,
            title: "Memory fit",
            findings: [finding]
        )
    }

    private func makeRuntimeDiscoverySection(customRuntimeSearchPath: String?) -> LocalModelDiagnosticsReport.Section {
        let candidates = detectHomebrewRuntimeCandidates()
        let customCandidates = detectCustomRuntimeCandidates(customRuntimeSearchPath: customRuntimeSearchPath)

        var findings: [LocalModelDiagnosticsReport.Finding] = []

        if let customFinding = customCandidates.finding {
            findings.append(customFinding)
        }

        if candidates.isEmpty {
            findings.append(.init(
                severity: .warning,
                title: "Homebrew runtime not detected",
                details: "AutoComp did not find a Homebrew prefix at /opt/homebrew or /usr/local.",
                remediation: "If you installed llama.cpp with Homebrew, ensure Homebrew is installed. Otherwise, install via Homebrew or configure a custom runtime location."
            ))
        } else {
            for candidate in candidates {
                let searchPaths = candidate.librarySearchPaths.isEmpty ? "(no lib directories found)" : candidate.librarySearchPaths.joined(separator: "\n")
                let dylibs = candidate.dylibCandidates.isEmpty ? "(no known dylibs found)" : candidate.dylibCandidates.joined(separator: "\n")

                findings.append(.init(
                    severity: .info,
                    title: "Homebrew prefix detected: \(candidate.prefix)",
                    details: "Library search paths:\n\(searchPaths)\n\nDylib candidates:\n\(dylibs)",
                    remediation: candidate.dylibCandidates.isEmpty ? "Install llama.cpp via Homebrew (brew install llama.cpp) or build it and place dylibs under the Homebrew prefix." : nil
                ))
            }
        }

        let dylibCandidates = collectAllDylibCandidates(homebrewCandidates: candidates, custom: customCandidates)
        findings.append(contentsOf: makeDylibValidationFindings(dylibCandidates: dylibCandidates))
        findings.append(contentsOf: makeDylibArchitectureFindings(dylibCandidates: dylibCandidates))

        return LocalModelDiagnosticsReport.Section(
            kind: .runtime,
            title: "Local runtime discovery",
            findings: findings
        )
    }

    private func collectAllDylibCandidates(
        homebrewCandidates: [HomebrewRuntimeCandidate],
        custom: CustomRuntimeDiscoveryResult
    ) -> [String] {
        var results: [String] = []
        results.append(contentsOf: custom.dylibCandidates)
        for candidate in homebrewCandidates {
            results.append(contentsOf: candidate.dylibCandidates)
        }
        // Preserve order while de-duping.
        var seen: Set<String> = []
        return results.filter { seen.insert($0).inserted }
    }

    private func makeDylibValidationFindings(dylibCandidates: [String]) -> [LocalModelDiagnosticsReport.Finding] {
        guard !dylibCandidates.isEmpty else {
            return [LocalModelDiagnosticsReport.Finding(
                severity: .warning,
                title: "No llama.cpp dylib candidates found",
                details: "AutoComp could not find libllama.dylib or libggml*.dylib in the discovered runtime locations.",
                remediation: "Install llama.cpp via Homebrew (brew install llama.cpp) or build llama.cpp and configure a custom runtime folder containing the dylibs."
            )]
        }

        let results = dylibCandidates.map { checkDylibLoadability(atPath: $0) }

        let okCount = results.filter { $0.status == .ok }.count
        var detailLines: [String] = []
        for result in results {
            switch result.status {
            case .ok:
                detailLines.append("✅ \(result.path)")
            case .missing:
                detailLines.append("❌ missing: \(result.path)")
            case .notAFile:
                detailLines.append("❌ not a file: \(result.path)")
            case .unreadable:
                detailLines.append("❌ unreadable: \(result.path)")
            case .dlopenFailed:
                let err = result.dlopenError ?? "(unknown dlopen error)"
                detailLines.append("❌ dlopen failed: \(result.path)\n    \(err)")
            }
        }

        let severity: LocalModelDiagnosticsReport.Severity
        let title: String
        let remediation: String?

        if okCount == results.count {
            severity = .info
            title = "llama.cpp dylibs are present"
            remediation = nil
        } else if okCount > 0 {
            severity = .warning
            title = "Some llama.cpp dylib candidates are not usable"
            remediation = "Fix missing/unreadable files, then rebuild/reinstall llama.cpp if needed. If you installed via Homebrew: brew reinstall llama.cpp. If you built manually: ensure libllama.dylib and libggml*.dylib are built for your Mac and placed in a single folder. If files were downloaded, remove quarantine: xattr -dr com.apple.quarantine <folder>."
        } else {
            severity = .error
            title = "llama.cpp dylibs are not usable"
            remediation = "Install or rebuild llama.cpp and ensure libllama.dylib and libggml*.dylib are readable and built for your Mac. Homebrew: brew install llama.cpp (or brew reinstall llama.cpp). Manual builds: copy/symlink dylibs into one folder and configure it in Settings. If files were downloaded, remove quarantine: xattr -dr com.apple.quarantine <folder>."
        }

        return [LocalModelDiagnosticsReport.Finding(
            severity: severity,
            title: title,
            details: detailLines.joined(separator: "\n"),
            remediation: remediation
        )]
    }

    public func checkDylibLoadability(atPath path: String) -> DylibLoadabilityCheckResult {
        let fileManager = FileManager.default

        var isDir = ObjCBool(false)
        guard fileManager.fileExists(atPath: path, isDirectory: &isDir) else {
            return DylibLoadabilityCheckResult(path: path, status: .missing, dlopenError: nil)
        }

        guard !isDir.boolValue else {
            return DylibLoadabilityCheckResult(path: path, status: .notAFile, dlopenError: nil)
        }

        guard fileManager.isReadableFile(atPath: path) else {
            return DylibLoadabilityCheckResult(path: path, status: .unreadable, dlopenError: nil)
        }

        // IMPORTANT: dlopen() executes library initializers, which can abort for some llama.cpp/ggml
        // builds if loaded in an unexpected context (e.g., during unit tests or without expected env).
        // To keep diagnostics safe, we do not dlopen here.
        //
        // Instead we report the library as "present" when it is a readable regular file. Deeper
        // validation (architecture/deps) is handled separately.
        return DylibLoadabilityCheckResult(path: path, status: .ok, dlopenError: nil)
    }

    private enum MachOArchitecture: String, Equatable, Sendable {
        case arm64
        case x86_64
        case unknown
    }

    private struct MachOScanResult: Equatable, Sendable {
        let path: String
        let isMachO: Bool
        let architectures: [MachOArchitecture]
        let parseError: String?
    }

    private func makeDylibArchitectureFindings(dylibCandidates: [String]) -> [LocalModelDiagnosticsReport.Finding] {
        guard !dylibCandidates.isEmpty else { return [] }

        let expectedArch: MachOArchitecture = {
            #if arch(arm64)
            return .arm64
            #elseif arch(x86_64)
            return .x86_64
            #else
            return .unknown
            #endif
        }()

        let scans = dylibCandidates.map { scanMachOArchitectures(atPath: $0) }

        var detailLines: [String] = []
        var hasMismatch = false
        var hasNonMachO = false

        for scan in scans {
            if !scan.isMachO {
                hasNonMachO = true
                let extra = scan.parseError.map { " (\($0))" } ?? ""
                detailLines.append("⚠️ not Mach-O: \(scan.path)\(extra)")
                continue
            }

            let archList = scan.architectures.map { $0.rawValue }.joined(separator: ", ")
            detailLines.append("• \(scan.path) [\(archList.isEmpty ? "unknown" : archList)]")

            if expectedArch != .unknown, !scan.architectures.isEmpty, !scan.architectures.contains(expectedArch) {
                hasMismatch = true
            }
        }

        let severity: LocalModelDiagnosticsReport.Severity = hasMismatch ? .error : (hasNonMachO ? .warning : .info)

        let expectedLine: String = {
            switch expectedArch {
            case .arm64: return "Expected architecture: arm64"
            case .x86_64: return "Expected architecture: x86_64"
            case .unknown: return "Expected architecture: unknown"
            }
        }()

        let remediation: String? = hasMismatch
            ? "Install or build llama.cpp dylibs for \(expectedArch.rawValue). If you have both Intel and Apple Silicon builds, ensure AutoComp is running natively (not under Rosetta) and select matching dylibs. Homebrew users can try: brew reinstall llama.cpp."
            : nil

        return [LocalModelDiagnosticsReport.Finding(
            severity: severity,
            title: "Dylib architecture compatibility",
            details: ([expectedLine] + detailLines).joined(separator: "\n"),
            remediation: remediation
        )]
    }

    private func scanMachOArchitectures(atPath path: String) -> MachOScanResult {
        let fileManager = FileManager.default
        var isDir = ObjCBool(false)
        guard fileManager.fileExists(atPath: path, isDirectory: &isDir) else {
            return MachOScanResult(path: path, isMachO: false, architectures: [], parseError: "missing")
        }
        guard !isDir.boolValue else {
            return MachOScanResult(path: path, isMachO: false, architectures: [], parseError: "is a directory")
        }
        guard fileManager.isReadableFile(atPath: path) else {
            return MachOScanResult(path: path, isMachO: false, architectures: [], parseError: "unreadable")
        }

        guard let data = try? Data(contentsOf: URL(fileURLWithPath: path), options: [.mappedIfSafe]) else {
            return MachOScanResult(path: path, isMachO: false, architectures: [], parseError: "I/O failure")
        }

        func readU32(_ offset: Int) -> UInt32? {
            guard data.count >= offset + 4 else { return nil }
            return data.withUnsafeBytes { raw in
                raw.load(fromByteOffset: offset, as: UInt32.self)
            }
        }

        guard let magic = readU32(0) else {
            return MachOScanResult(path: path, isMachO: false, architectures: [], parseError: "truncated")
        }

        let MH_MAGIC: UInt32 = 0xfeedface
        let MH_MAGIC_64: UInt32 = 0xfeedfacf
        let MH_CIGAM: UInt32 = 0xcefaedfe
        let MH_CIGAM_64: UInt32 = 0xcffaedfe
        let FAT_MAGIC: UInt32 = 0xcafebabe
        let FAT_CIGAM: UInt32 = 0xbebafeca
        let FAT_MAGIC_64: UInt32 = 0xcafebabf
        let FAT_CIGAM_64: UInt32 = 0xbfbafeca

        func cpuTypeToArch(_ cpuType: Int32) -> MachOArchitecture {
            if cpuType == CPU_TYPE_ARM64 { return .arm64 }
            if cpuType == CPU_TYPE_X86_64 { return .x86_64 }
            return .unknown
        }

        // Thin Mach-O.
        if magic == MH_MAGIC || magic == MH_MAGIC_64 || magic == MH_CIGAM || magic == MH_CIGAM_64 {
            let swap = (magic == MH_CIGAM || magic == MH_CIGAM_64)
            guard var cpuTypeU32 = readU32(4) else {
                return MachOScanResult(path: path, isMachO: true, architectures: [], parseError: "truncated header")
            }
            if swap { cpuTypeU32 = cpuTypeU32.byteSwapped }
            let cpuType = Int32(bitPattern: cpuTypeU32)
            return MachOScanResult(path: path, isMachO: true, architectures: [cpuTypeToArch(cpuType)], parseError: nil)
        }

        // Fat/universal Mach-O.
        if magic == FAT_MAGIC || magic == FAT_CIGAM || magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64 {
            let swap = (magic == FAT_CIGAM || magic == FAT_CIGAM_64)
            guard var nfat = readU32(4) else {
                return MachOScanResult(path: path, isMachO: true, architectures: [], parseError: "truncated fat header")
            }
            if swap { nfat = nfat.byteSwapped }

            var archs: [MachOArchitecture] = []
            let is64 = (magic == FAT_MAGIC_64 || magic == FAT_CIGAM_64)
            let archSize = is64 ? 32 : 20

            var offset = 8
            for _ in 0..<Int(nfat) {
                guard var cpuTypeU32 = readU32(offset) else { break }
                if swap { cpuTypeU32 = cpuTypeU32.byteSwapped }
                let arch = cpuTypeToArch(Int32(bitPattern: cpuTypeU32))
                if arch != .unknown && !archs.contains(arch) {
                    archs.append(arch)
                }
                offset += archSize
            }

            return MachOScanResult(path: path, isMachO: true, architectures: archs, parseError: nil)
        }

        return MachOScanResult(path: path, isMachO: false, architectures: [], parseError: "unknown magic 0x\(String(magic, radix: 16))")
    }

    private func queryVMStatPageFreeBytes() -> Int64? {
        // On macOS, `host_statistics64` with `vm_statistics64` provides free/inactive counts.
        // We use free + inactive as a coarse "available" proxy.
        var pageSize: vm_size_t = 0
        let pageSizeKern = host_page_size(mach_host_self(), &pageSize)
        guard pageSizeKern == KERN_SUCCESS else { return nil }

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)

        let result: kern_return_t = withUnsafeMutablePointer(to: &stats) { statsPtr in
            statsPtr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { intPtr in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, intPtr, &count)
            }
        }

        guard result == KERN_SUCCESS else { return nil }

        let freePages = Int64(stats.free_count)
        let inactivePages = Int64(stats.inactive_count)
        return (freePages + inactivePages) * Int64(pageSize)
    }

    private func querySystemMemoryPressureLevel() -> String? {
        // Best-effort: macOS memory pressure is available via dispatch source.
        // Here we return nil unless we can infer a stable value.
        return nil
    }

    public struct MemoryEstimate: Equatable, Sendable {
        public let weightsBytes: Int64
        public let kvCacheBytesLow: Int64
        public let kvCacheBytesHigh: Int64
        public let overheadBytesLow: Int64
        public let overheadBytesHigh: Int64
        public let assumptions: [String]
        public let usesFallbackContextLength: Bool

        public var totalLowBytes: Int64 {
            weightsBytes + kvCacheBytesLow + overheadBytesLow
        }

        public var totalHighBytes: Int64 {
            weightsBytes + kvCacheBytesHigh + overheadBytesHigh
        }

        public var totalRangeDescription: String {
            let low = ByteCountFormatter.string(fromByteCount: totalLowBytes, countStyle: .memory)
            let high = ByteCountFormatter.string(fromByteCount: totalHighBytes, countStyle: .memory)
            return "\(low) – \(high)"
        }
    }

    /// Estimates a conservative memory range for local inference.
    ///
    /// This is intentionally approximate because GGUF does not reliably encode all information needed
    /// (e.g., exact number of layers, embedding size) without parsing tensors.
    ///
    /// - Parameters:
    ///   - fileSizeBytes: Model file size.
    ///   - contextLength: Context length from metadata if available.
    ///   - quantizationLabel: Coarse quantization label.
    public func estimateMemoryRequirements(
        fileSizeBytes: Int64?,
        contextLength: Int?,
        quantizationLabel: String?
    ) -> MemoryEstimate {
        let weights = max(0, fileSizeBytes ?? 0)

        let ctx: Int
        let usesFallback: Bool
        if let contextLength, contextLength > 0 {
            ctx = contextLength
            usesFallback = false
        } else {
            ctx = 4096
            usesFallback = true
        }

        // KV cache is model-dependent; we pick a heuristic based on common llama-family sizes.
        // Per-token KV bytes roughly scales with hidden size and layer count.
        // We use a broad range: 0.5 MiB – 2 MiB per 1k context.
        let kvPer1kLow: Int64 = 512 * 1024
        let kvPer1kHigh: Int64 = 2 * 1024 * 1024
        let ctxUnits = Int64((Double(ctx) / 1024.0).rounded(.up))
        let kvLow = kvPer1kLow * ctxUnits
        let kvHigh = kvPer1kHigh * ctxUnits

        // Overhead accounts for runtime allocations, rope buffers, scratch, and safety headroom.
        // Quantized models often have extra buffers; use 10–30% of weights.
        let overheadLow = Int64(Double(weights) * 0.10)
        let overheadHigh = Int64(Double(weights) * 0.30)

        var assumptions: [String] = []
        if usesFallback {
            assumptions.append("Context length unknown; assumed \(ctx).")
        } else {
            assumptions.append("KV cache estimated from context length \(ctx).")
        }
        assumptions.append("KV cache heuristic range: 0.5–2 MiB per 1k context.")
        if let quantizationLabel {
            assumptions.append("Quantization: \(quantizationLabel) (file size already reflects weights).")
        } else {
            assumptions.append("Quantization unknown; using file size as weights proxy.")
        }
        assumptions.append("Overhead estimated as 10–30% of weights.")

        return MemoryEstimate(
            weightsBytes: weights,
            kvCacheBytesLow: kvLow,
            kvCacheBytesHigh: kvHigh,
            overheadBytesLow: overheadLow,
            overheadBytesHigh: overheadHigh,
            assumptions: assumptions,
            usesFallbackContextLength: usesFallback
        )
    }

    /// Lightweight GGUF parser.
    ///
    /// It validates the GGUF magic and attempts to extract a few commonly used metadata keys:
    /// - general.architecture (string)
    /// - llama.context_length (u32)
    /// - general.file_type (u32) which is mapped to a coarse quantization label
    public func parseGGUFHeader(atPath path: String) throws -> GGUFHeaderSummary {
        guard FileManager.default.isReadableFile(atPath: path) else {
            throw GGUFHeaderParseError.fileNotReadable
        }

        let url = URL(fileURLWithPath: path)
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw GGUFHeaderParseError.ioFailure
        }

        defer { try? handle.close() }

        // Read the first 1 MiB which is enough for header + key/value metadata for typical GGUF files.
        let maxBytes = 1_048_576
        let data: Data
        do {
            if #available(macOS 10.15.4, *) {
                data = try handle.read(upToCount: maxBytes) ?? Data()
            } else {
                data = handle.readData(ofLength: maxBytes)
            }
        } catch {
            throw GGUFHeaderParseError.ioFailure
        }

        var cursor = GGUFDataCursor(data)

        guard cursor.readASCII(count: 4) == "GGUF" else {
            throw GGUFHeaderParseError.invalidMagic
        }

        // version (u32)
        _ = cursor.readUInt32()

        // tensorCount (u64), kvCount (u64)
        guard cursor.readUInt64() != nil, cursor.readUInt64() != nil else {
            throw GGUFHeaderParseError.unsupportedFormat
        }

        // Iterate over key-value entries.
        var architecture: String?
        var contextLength: Int?
        var fileType: UInt32?

        while !cursor.isAtEnd {
            guard let key = cursor.readString() else { break }
            guard let valueTypeRaw = cursor.readUInt32() else { break }

            guard let valueType = GGUFValueType(rawValue: valueTypeRaw) else {
                // Unknown type; cannot reliably skip.
                break
            }

            if key == "general.architecture" {
                architecture = cursor.readValueAsString(type: valueType)
            } else if key == "llama.context_length" {
                contextLength = cursor.readValueAsInt(type: valueType)
                _ = architecture // keep compiler happy
            } else if key == "general.file_type" {
                if let v = cursor.readValueAsInt(type: valueType) {
                    fileType = UInt32(v)
                }
            } else {
                // Skip value
                cursor.skipValue(type: valueType)
            }

            if architecture != nil, contextLength != nil, fileType != nil {
                break
            }
        }

        let quantization = fileType.map { GGUFFileType(rawValue: $0)?.label ?? "type \($0)" }

        return GGUFHeaderSummary(
            architecture: architecture,
            contextLength: contextLength,
            quantization: quantization
        )
    }
}

private enum GGUFValueType: UInt32 {
    case uint8 = 0
    case int8 = 1
    case uint16 = 2
    case int16 = 3
    case uint32 = 4
    case int32 = 5
    case float32 = 6
    case bool = 7
    case string = 8
    case array = 9
    case uint64 = 10
    case int64 = 11
    case float64 = 12
}

private enum GGUFFileType: UInt32 {
    // Coarse mapping; values follow common gguf "general.file_type" codes used by llama.cpp.
    case allF32 = 0
    case mostlyF16 = 1
    case mostlyQ4_0 = 2
    case mostlyQ4_1 = 3
    case mostlyQ5_0 = 8
    case mostlyQ5_1 = 9
    case mostlyQ8_0 = 7
    case mostlyQ2_K = 10
    case mostlyQ3_K_S = 11
    case mostlyQ3_K_M = 12
    case mostlyQ3_K_L = 13
    case mostlyQ4_K_S = 14
    case mostlyQ4_K_M = 15
    case mostlyQ5_K_S = 16
    case mostlyQ5_K_M = 17
    case mostlyQ6_K = 18

    var label: String {
        switch self {
        case .allF32: return "F32"
        case .mostlyF16: return "F16"
        case .mostlyQ2_K: return "Q2_K"
        case .mostlyQ3_K_S: return "Q3_K_S"
        case .mostlyQ3_K_M: return "Q3_K_M"
        case .mostlyQ3_K_L: return "Q3_K_L"
        case .mostlyQ4_0: return "Q4_0"
        case .mostlyQ4_1: return "Q4_1"
        case .mostlyQ4_K_S: return "Q4_K_S"
        case .mostlyQ4_K_M: return "Q4_K_M"
        case .mostlyQ5_0: return "Q5_0"
        case .mostlyQ5_1: return "Q5_1"
        case .mostlyQ5_K_S: return "Q5_K_S"
        case .mostlyQ5_K_M: return "Q5_K_M"
        case .mostlyQ6_K: return "Q6_K"
        case .mostlyQ8_0: return "Q8_0"
        }
    }
}

private struct GGUFDataCursor {
    private let data: Data
    private(set) var offset: Int = 0

    init(_ data: Data) {
        self.data = data
    }

    var isAtEnd: Bool {
        offset >= data.count
    }

    mutating func readASCII(count: Int) -> String? {
        guard let sub = readBytes(count: count) else { return nil }
        return String(data: sub, encoding: .ascii)
    }

    mutating func readBytes(count: Int) -> Data? {
        guard offset + count <= data.count else { return nil }
        let sub = data.subdata(in: offset..<(offset + count))
        offset += count
        return sub
    }

    mutating func readUInt32() -> UInt32? {
        guard let sub = readBytes(count: 4) else { return nil }
        return UInt32(littleEndian: sub.withUnsafeBytes { $0.load(as: UInt32.self) })
    }

    mutating func readUInt64() -> UInt64? {
        guard let sub = readBytes(count: 8) else { return nil }
        return UInt64(littleEndian: sub.withUnsafeBytes { $0.load(as: UInt64.self) })
    }

    mutating func readString() -> String? {
        guard let length = readUInt64() else { return nil }
        guard length <= UInt64(Int.max) else { return nil }
        guard let bytes = readBytes(count: Int(length)) else { return nil }
        return String(data: bytes, encoding: .utf8)
    }

    mutating func skipValue(type: GGUFValueType) {
        switch type {
        case .uint8, .int8, .bool:
            _ = readBytes(count: 1)
        case .uint16, .int16:
            _ = readBytes(count: 2)
        case .uint32, .int32, .float32:
            _ = readBytes(count: 4)
        case .uint64, .int64, .float64:
            _ = readBytes(count: 8)
        case .string:
            _ = readString()
        case .array:
            // array: u32 element type + u64 length + elements
            guard let elementTypeRaw = readUInt32(), let length = readUInt64() else { return }
            guard let elementType = GGUFValueType(rawValue: elementTypeRaw) else { return }
            for _ in 0..<length {
                skipValue(type: elementType)
                if isAtEnd { break }
            }
        }
    }

    mutating func readValueAsString(type: GGUFValueType) -> String? {
        switch type {
        case .string:
            return readString()
        default:
            skipValue(type: type)
            return nil
        }
    }

    mutating func readValueAsInt(type: GGUFValueType) -> Int? {
        switch type {
        case .uint8:
            return readBytes(count: 1)?.first.map { Int($0) }
        case .int8:
            guard let b = readBytes(count: 1)?.first else { return nil }
            return Int(Int8(bitPattern: b))
        case .uint16:
            guard let sub = readBytes(count: 2) else { return nil }
            let v = UInt16(littleEndian: sub.withUnsafeBytes { $0.load(as: UInt16.self) })
            return Int(v)
        case .int16:
            guard let sub = readBytes(count: 2) else { return nil }
            let v = Int16(littleEndian: sub.withUnsafeBytes { $0.load(as: Int16.self) })
            return Int(v)
        case .uint32:
            guard let v = readUInt32() else { return nil }
            return Int(v)
        case .int32:
            guard let sub = readBytes(count: 4) else { return nil }
            let v = Int32(littleEndian: sub.withUnsafeBytes { $0.load(as: Int32.self) })
            return Int(v)
        case .uint64:
            guard let v = readUInt64() else { return nil }
            return v > UInt64(Int.max) ? nil : Int(v)
        case .int64:
            guard let sub = readBytes(count: 8) else { return nil }
            let v = Int64(littleEndian: sub.withUnsafeBytes { $0.load(as: Int64.self) })
            return v > Int64(Int.max) ? nil : Int(v)
        default:
            skipValue(type: type)
            return nil
        }
    }
}
