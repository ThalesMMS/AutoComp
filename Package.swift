// swift-tools-version: 6.2

import PackageDescription
import Foundation

let hasLlamaRuntime = FileManager.default.fileExists(atPath: "/opt/homebrew/include/llama.h")
    && FileManager.default.fileExists(atPath: "/opt/homebrew/include/ggml.h")
    && FileManager.default.fileExists(atPath: "/opt/homebrew/lib/libllama.dylib")
    && FileManager.default.fileExists(atPath: "/opt/homebrew/lib/libggml.dylib")

let appDependencies: [Target.Dependency] = hasLlamaRuntime
    ? ["AutoCompCore", "AutoCompLlamaRuntime"]
    : ["AutoCompCore"]

var products: [Product] = [
    .executable(name: "AutoComp", targets: ["AutoCompApp"]),
    .library(name: "AutoCompCore", targets: ["AutoCompCore"])
]

var targets: [Target] = [
    .executableTarget(
        name: "AutoCompApp",
        dependencies: appDependencies
    ),
    .target(
        name: "AutoCompCore"
    ),
    .testTarget(
        name: "AutoCompCoreTests",
        dependencies: ["AutoCompCore"]
    ),
    .testTarget(
        name: "AutoCompAppTests",
        dependencies: ["AutoCompApp"]
    )
]

if hasLlamaRuntime {
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
                .unsafeFlags(["-I/opt/homebrew/include"], .when(platforms: [.macOS]))
            ],
            cxxSettings: [
                .unsafeFlags(["-I/opt/homebrew/include"], .when(platforms: [.macOS]))
            ],
            linkerSettings: [
                .unsafeFlags(["-L/opt/homebrew/lib"], .when(platforms: [.macOS])),
                .linkedLibrary("ggml", .when(platforms: [.macOS])),
                .linkedLibrary("ggml-base", .when(platforms: [.macOS])),
                .linkedLibrary("llama", .when(platforms: [.macOS]))
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
