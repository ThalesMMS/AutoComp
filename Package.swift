// swift-tools-version: 6.2

import PackageDescription
import Foundation

struct LlamaBuildFlags {
    let cFlags: [String]
    let linkerFlags: [String]
}

let environment = ProcessInfo.processInfo.environment
let llamaBuildFlags = resolveLlamaBuildFlags(environment: environment)

let appDependencies: [Target.Dependency] = llamaBuildFlags != nil
    ? ["AutoCompCore", "AutoCompLlamaRuntime"]
    : ["AutoCompCore"]
let appSwiftSettings: [SwiftSetting] = llamaBuildFlags != nil
    ? [.define("AUTOCOMP_LLAMA_RUNTIME", .when(platforms: [.macOS]))]
    : []

var products: [Product] = [
    .executable(name: "AutoComp", targets: ["AutoCompApp"]),
    .library(name: "AutoCompCore", targets: ["AutoCompCore"])
]

var targets: [Target] = [
    .executableTarget(
        name: "AutoCompApp",
        dependencies: appDependencies,
        swiftSettings: appSwiftSettings
    ),
    .target(
        name: "AutoCompCore"
    ),
    .testTarget(
        name: "AutoCompCoreTests",
        dependencies: ["AutoCompCore"],
        resources: [
            .process("Fixtures")
        ]
    ),
    .testTarget(
        name: "AutoCompAppTests",
        dependencies: ["AutoCompApp"],
        resources: [
            .process("Fixtures")
        ]
    )
]

if let llamaBuildFlags {
    products += [
        .executable(name: "AutoCompLlamaLoadHarness", targets: ["AutoCompLlamaLoadHarness"]),
        .library(name: "AutoCompLlamaRuntime", targets: ["AutoCompLlamaRuntime"])
    ]

    targets += [
        .executableTarget(
            name: "AutoCompLlamaLoadHarness",
            dependencies: ["AutoCompCore", "AutoCompLlamaRuntime"]
        ),
        .target(
            name: "CLlamaBridge",
            cSettings: [
                .unsafeFlags(llamaBuildFlags.cFlags, .when(platforms: [.macOS]))
            ],
            cxxSettings: [
                .unsafeFlags(llamaBuildFlags.cFlags, .when(platforms: [.macOS]))
            ],
            linkerSettings: [
                .unsafeFlags(llamaBuildFlags.linkerFlags, .when(platforms: [.macOS]))
            ]
        ),
        .target(
            name: "AutoCompLlamaRuntime",
            dependencies: ["AutoCompCore", "CLlamaBridge"]
        ),
        .testTarget(
            name: "AutoCompLlamaRuntimeTests",
            dependencies: ["AutoCompCore", "AutoCompLlamaRuntime"]
        )
    ]
}

let package = Package(
    name: "AutoComp",
    platforms: [
        .macOS(.v14)
    ],
    products: products,
    targets: targets
)

func resolveLlamaBuildFlags(environment: [String: String]) -> LlamaBuildFlags? {
    let enableValue = environment["AUTOCOMP_ENABLE_LLAMA_RUNTIME"] ?? ""
    let isExplicitlyEnabled = ["1", "true", "yes"].contains(enableValue.lowercased())
    let cFlagsValue = environment["AUTOCOMP_LLAMA_CFLAGS"] ?? ""
    let libsValue = environment["AUTOCOMP_LLAMA_LIBS"] ?? ""
    let hasManualFlags = !cFlagsValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        || !libsValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

    guard isExplicitlyEnabled || hasManualFlags else {
        return nil
    }

    if hasManualFlags {
        guard !cFlagsValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !libsValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            fatalError("""
            Local llama runtime was requested with manual flags, but one flag set is missing.
            Set both AUTOCOMP_LLAMA_CFLAGS and AUTOCOMP_LLAMA_LIBS, or unset them to use pkg-config llama.
            """)
        }

        return LlamaBuildFlags(
            cFlags: splitBuildFlags(cFlagsValue, variableName: "AUTOCOMP_LLAMA_CFLAGS"),
            linkerFlags: splitBuildFlags(libsValue, variableName: "AUTOCOMP_LLAMA_LIBS")
        )
    }

    let pkgConfigCheck = runCommand("/usr/bin/env", arguments: ["pkg-config", "--exists", "llama"])
    guard pkgConfigCheck.exitCode == 0 else {
        fatalError("""
        AUTOCOMP_ENABLE_LLAMA_RUNTIME=1 was set, but pkg-config could not find llama.
        Install a llama.cpp package that provides pkg-config metadata, run ./script/check_llama_pkg_config.sh, \
        or set AUTOCOMP_LLAMA_CFLAGS and AUTOCOMP_LLAMA_LIBS explicitly.
        \(pkgConfigCheck.output)
        """)
    }

    let pkgConfigPackages = llamaPkgConfigPackages()
    let cFlags = pkgConfigPackages.flatMap { runPkgConfig(arguments: ["--cflags", $0]) }
    let linkerFlags = pkgConfigPackages.flatMap { runPkgConfig(arguments: ["--libs", $0]) }
    guard !linkerFlags.isEmpty else {
        fatalError("""
        pkg-config llama returned no linker flags.
        Run ./script/check_llama_pkg_config.sh, or set AUTOCOMP_LLAMA_CFLAGS and AUTOCOMP_LLAMA_LIBS explicitly.
        """)
    }

    return LlamaBuildFlags(cFlags: cFlags, linkerFlags: linkerFlags)
}

func llamaPkgConfigPackages() -> [String] {
    var packages: [String] = []
    if runCommand("/usr/bin/env", arguments: ["pkg-config", "--exists", "ggml"]).exitCode == 0 {
        packages.append("ggml")
    }
    packages.append("llama")
    return packages
}

func runPkgConfig(arguments: [String]) -> [String] {
    let result = runCommand("/usr/bin/env", arguments: ["pkg-config"] + arguments)
    guard result.exitCode == 0 else {
        fatalError("""
        pkg-config \(arguments.joined(separator: " ")) failed while configuring the optional llama runtime.
        Run ./script/check_llama_pkg_config.sh, or set AUTOCOMP_LLAMA_CFLAGS and AUTOCOMP_LLAMA_LIBS explicitly.
        \(result.output)
        """)
    }

    return splitBuildFlags(result.output, variableName: "pkg-config \(arguments.joined(separator: " "))")
}

func runCommand(_ executable: String, arguments: [String]) -> (exitCode: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments

    let output = Pipe()
    process.standardOutput = output
    process.standardError = output

    do {
        try process.run()
        process.waitUntilExit()
    } catch {
        return (127, "\(error)")
    }

    let data = output.fileHandleForReading.readDataToEndOfFile()
    let string = String(data: data, encoding: .utf8) ?? ""
    return (process.terminationStatus, string.trimmingCharacters(in: .whitespacesAndNewlines))
}

func splitBuildFlags(_ value: String, variableName: String) -> [String] {
    var flags: [String] = []
    var current = ""
    var quote: Character?
    var isEscaped = false

    for character in value {
        if isEscaped {
            current.append(character)
            isEscaped = false
            continue
        }

        if character == "\\" {
            isEscaped = true
            continue
        }

        if let activeQuote = quote {
            if character == activeQuote {
                quote = nil
            } else {
                current.append(character)
            }
            continue
        }

        if character == "'" || character == "\"" {
            quote = character
            continue
        }

        if character.isWhitespace {
            if !current.isEmpty {
                flags.append(current)
                current = ""
            }
            continue
        }

        current.append(character)
    }

    if isEscaped {
        current.append("\\")
    }

    if let quote {
        fatalError("Unterminated \(quote) quote in \(variableName).")
    }

    if !current.isEmpty {
        flags.append(current)
    }

    return flags
}
