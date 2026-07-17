import AutoCompBenchKit
import AutoCompCore
import CoreGraphics
import Foundation

private struct RemoteBenchProvider: BenchCompletionProvider {
    let provider: RemoteCompletionProvider

    func sample(for testCase: BenchCase, configuration: BenchConfiguration) async -> BenchProviderSample {
        let context = TextContext(
            app: AppIdentity(bundleID: testCase.appBundleID, displayName: testCase.appDisplayName, processID: 1),
            domain: testCase.domain,
            focusedElementID: "bench-field",
            textBeforeCursor: testCase.beforeCursor,
            textAfterCursor: testCase.afterCursor,
            selectedText: testCase.selectedText,
            caretRect: CGRect(x: 100, y: 100, width: 2, height: 20),
            caretGeometryQuality: testCase.geometryQuality
        )
        do {
            let suggestion = try await provider.complete(
                context: context,
                privacySettings: PrivacySettings(),
                visualContext: nil,
                clipboardContext: nil,
                personalizationSamples: []
            )
            return BenchProviderSample(output: suggestion.rawText ?? suggestion.visibleText, latencyMs: suggestion.latencyMs)
        } catch {
            FileHandle.standardError.write(Data("remote provider failed for \(testCase.id): \(error)\n".utf8))
            return BenchProviderSample(skip: .providerFailure)
        }
    }
}

private struct Options {
    var mode = "fixture"
    var suite = "all"
    var dataset = "Benchmarks/Datasets"
    var output: String?
    var baseline: String?
    var allowRemote = false
    var compare: BenchNormalizationMode?

    init(arguments: [String]) throws {
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            func value() throws -> String {
                guard index + 1 < arguments.count else { throw CLIError.usage("Missing value after \(argument)") }
                index += 1; return arguments[index]
            }
            switch argument {
            case "--mode": mode = try value()
            case "--suite": suite = try value()
            case "--dataset": dataset = try value()
            case "--output": output = try value()
            case "--baseline": baseline = try value()
            case "--allow-remote": allowRemote = true
            case "--compare":
                guard let mode = BenchNormalizationMode(rawValue: try value()) else {
                    throw CLIError.usage("--compare must be production or identity")
                }
                compare = mode
            case "--help", "-h": throw CLIError.help
            default: throw CLIError.usage("Unknown argument: \(argument)")
            }
            index += 1
        }
    }
}

private enum CLIError: LocalizedError {
    case help
    case usage(String)
    case remoteConsent
    case remoteConfiguration(String)
    case baselineRegressions([String])
    case benchmarkRegressions(Int)

    var errorDescription: String? {
        switch self {
        case .help: return Self.usageText
        case .usage(let message): return "\(message)\n\n\(Self.usageText)"
        case .remoteConsent: return "remote-live requires --allow-remote; only synthetic committed cases are sent"
        case .remoteConfiguration(let name): return "remote-live requires environment variable \(name)"
        case .baselineRegressions(let messages): return "Baseline regressions: \(messages.joined(separator: ", "))"
        case .benchmarkRegressions(let count): return "Benchmark contains \(count) regression(s)"
        }
    }

    static let usageText = """
    Usage: AutoCompBench [options]
      --mode fixture|local-live|remote-live
      --suite all|smoke|core|edge|policy|latency
      --dataset PATH       JSONL file or dataset directory
      --output PREFIX      writes PREFIX.json and PREFIX.md
      --baseline PATH      compare against a versioned report and fail on regression
      --compare MODE       run A/B against production (production|identity)
      --allow-remote       explicit consent for remote-live synthetic fixtures

    remote-live reads AUTOCOMP_BENCH_REMOTE_BASE_URL, AUTOCOMP_BENCH_REMOTE_MODEL,
    AUTOCOMP_BENCH_REMOTE_API_KEY, and optional AUTOCOMP_BENCH_REMOTE_TIMEOUT.
    """
}

@main
private enum AutoCompBenchCLI {
    static func main() async {
        do {
            let options = try Options(arguments: Array(CommandLine.arguments.dropFirst()))
            let datasetURL = URL(fileURLWithPath: options.dataset)
            let loadedCases: [BenchCase]
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: datasetURL.path, isDirectory: &isDirectory), isDirectory.boolValue {
                loadedCases = try BenchIO.loadDirectory(datasetURL, suite: options.suite)
            } else {
                let loaded = try BenchIO.loadJSONL(at: datasetURL)
                loadedCases = options.suite == "all" ? loaded : loaded.filter { $0.suite == options.suite }
            }
            let env = ProcessInfo.processInfo.environment
            let cases: [BenchCase]
            switch options.mode {
            case "remote-live":
                cases = loadedCases.map {
                    $0.reporting(
                        backend: "remote-openai-compatible",
                        modelRow: env["AUTOCOMP_BENCH_REMOTE_MODEL"] ?? "remote-model"
                    )
                }
            case "local-live":
                cases = loadedCases.map { $0.reporting(backend: "local-llama", modelRow: "runtime-unavailable") }
            default:
                cases = loadedCases
            }
            guard !cases.isEmpty else { throw CLIError.usage("No cases selected") }

            let provider: any BenchCompletionProvider
            switch options.mode {
            case "fixture": provider = FixtureBenchProvider()
            case "local-live": provider = SkippingBenchProvider(reason: .localRuntimeUnavailable)
            case "remote-live": provider = try remoteProvider(options: options)
            default: throw CLIError.usage("Unsupported mode: \(options.mode)")
            }

            let commit = gitCommit()
            let runner = BenchRunner()
            var report = await runner.run(
                cases: cases, provider: provider, configuration: .production,
                mode: options.mode, manifestCommit: commit
            )
            var baselineRegressions: [String] = []
            if let baselinePath = options.baseline {
                let baseline = try JSONDecoder().decode(BenchReport.self, from: Data(contentsOf: URL(fileURLWithPath: baselinePath)))
                baselineRegressions = BenchIO.regressionMessages(report: report, baseline: baseline)
                report.baselineComparison = BenchBaselineComparison(
                    baselineManifestCommit: baseline.manifestCommit,
                    regressions: baselineRegressions
                )
            }
            try emit(report, output: options.output)

            if let compare = options.compare {
                let comparison = await runner.run(
                    cases: cases, provider: provider,
                    configuration: BenchConfiguration(id: compare.rawValue, normalization: compare),
                    mode: options.mode, manifestCommit: commit
                )
                let text = BenchIO.abMarkdown(report, comparison)
                if let output = options.output {
                    try text.write(toFile: output + "-ab.md", atomically: true, encoding: .utf8)
                } else { print(text) }
            }

            if !baselineRegressions.isEmpty {
                throw CLIError.baselineRegressions(baselineRegressions)
            }

            if report.metrics.wrongShow > 0
                || report.metrics.incorrectSuppression > 0
                || report.metrics.schedulingMismatches > 0
                || report.metrics.reuseMismatches > 0
                || report.metrics.speculationMismatches > 0 {
                throw CLIError.benchmarkRegressions(
                    report.metrics.wrongShow
                        + report.metrics.incorrectSuppression
                        + report.metrics.schedulingMismatches
                        + report.metrics.reuseMismatches
                        + report.metrics.speculationMismatches
                )
            }
        } catch CLIError.help {
            print(CLIError.usageText)
        } catch {
            FileHandle.standardError.write(Data("AutoCompBench: \(error.localizedDescription)\n".utf8))
            Foundation.exit(EXIT_FAILURE)
        }
    }

    private static func remoteProvider(options: Options) throws -> any BenchCompletionProvider {
        guard options.allowRemote else { throw CLIError.remoteConsent }
        let env = ProcessInfo.processInfo.environment
        func required(_ name: String) throws -> String {
            guard let value = env[name], !value.isEmpty else { throw CLIError.remoteConfiguration(name) }
            return value
        }
        let configuration = RemoteCompletionConfiguration(
            baseURL: try required("AUTOCOMP_BENCH_REMOTE_BASE_URL"),
            apiKey: try required("AUTOCOMP_BENCH_REMOTE_API_KEY"),
            model: try required("AUTOCOMP_BENCH_REMOTE_MODEL"),
            timeoutSeconds: Double(env["AUTOCOMP_BENCH_REMOTE_TIMEOUT"] ?? "30") ?? 30
        )
        return RemoteBenchProvider(provider: RemoteCompletionProvider(configuration: configuration))
    }

    private static func emit(_ report: BenchReport, output: String?) throws {
        let json = try BenchIO.json(report)
        let markdown = BenchIO.markdown(report)
        if let output {
            try json.write(to: URL(fileURLWithPath: output + ".json"), options: .atomic)
            try markdown.write(toFile: output + ".md", atomically: true, encoding: .utf8)
        } else { print(markdown) }
    }

    private static func gitCommit() -> String {
        let process = Process(); let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "rev-parse", "HEAD"]
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        do {
            try process.run(); process.waitUntilExit()
            guard process.terminationStatus == 0 else { return "unknown" }
            return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"
        } catch { return "unknown" }
    }
}
